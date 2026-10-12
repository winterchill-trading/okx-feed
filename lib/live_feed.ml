open! Core
open Async
module Md = Market_data
module Ws = Venue_net.Ws_client

let ping_interval = Time_ns.Span.of_sec 20.

let args (stream : Md.Stream.t) ~symbols =
  let on channel = List.map symbols ~f:(fun inst_id -> { Wire.Arg.channel; inst_id }) in
  match stream with
  | Trades -> on Wire.trades
  | Bbo -> on Wire.bbo_tbt
  | L2 -> on Wire.books
  | Funding ->
    let symbols = List.filter symbols ~f:(String.is_suffix ~suffix:"-SWAP") in
    let on channel = List.map symbols ~f:(fun inst_id -> { Wire.Arg.channel; inst_id }) in
    on Wire.funding_rate
    @ on Wire.mark_price
    @ List.map
        (List.dedup_and_sort
           (List.map symbols ~f:Normalizer.index_of)
           ~compare:String.compare)
        ~f:(fun inst_id -> { Wire.Arg.channel = Wire.index_tickers; inst_id })
  | Private -> raise_s [%message "Live_feed: no public channel for the private stream"]
;;

let create ?on_raw (config : Config.t) ~symbols ~streams =
  let streams = List.dedup_and_sort streams ~compare:Md.Stream.compare in
  if List.mem streams Private ~equal:Md.Stream.equal
  then raise_s [%message "Live_feed.create: the private stream is not a market feed"];
  let trades_r, trades_w = Pipe.create () in
  let bbo_r, bbo_w = Pipe.create () in
  let l2_r, l2_w = Pipe.create () in
  let funding_r, funding_w = Pipe.create () in
  let emit : Md.Event.t -> unit = function
    | Trade x -> Pipe.write_without_pushback_if_open trades_w x
    | Bbo x -> Pipe.write_without_pushback_if_open bbo_w x
    | L2 x -> Pipe.write_without_pushback_if_open l2_w x
    | Funding x -> Pipe.write_without_pushback_if_open funding_w x
  in
  let connect stream args =
    let name = Md.Stream.to_string stream in
    let normalizer = Normalizer.create () in
    let on_connect ws =
      if Ws.reconnects ws > 0
      then (
        Log.Global.info "okx feed: %s reconnected, resubscribing" name;
        Normalizer.reset normalizer);
      Ws.send ws (Wire.Request.to_string Subscribe args)
    in
    let resubscribe ws arg =
      let%bind () = Ws.send ws (Wire.Request.to_string Unsubscribe [ arg ]) in
      Ws.send ws (Wire.Request.to_string Subscribe [ arg ])
    in
    let%map ws =
      Ws.connect
        ~ping:(`Text ("ping", ping_interval))
        ~on_connect
        ~log_name:("okx feed " ^ name)
        ~url:config.url
        ()
      >>| Or_error.ok_exn
    in
    don't_wait_for
      (Pipe.iter_without_pushback (Ws.messages ws) ~f:(fun frame ->
         let recv_ts = Time_ns.now () in
         Option.iter on_raw ~f:(fun on_raw -> on_raw ~stream ~recv_ts frame);
         match Normalizer.frame normalizer ~recv_ts frame with
         | Error error ->
           Log.Global.error_s
             [%message
               "okx feed: cannot use frame"
                 ~stream:name
                 (frame : string)
                 (error : Error.t)]
         | Ok { events; resubscribe = args } ->
           List.iter events ~f:emit;
           List.iter args ~f:(fun arg -> don't_wait_for (resubscribe ws arg))));
    ws
  in
  let opened = ref [] in
  let close_all () = Deferred.List.iter !opened ~how:`Parallel ~f:Ws.close in
  let%bind () =
    match%bind
      Monitor.try_with (fun () ->
        Deferred.List.iter streams ~how:`Sequential ~f:(fun stream ->
          match args stream ~symbols with
          | [] ->
            Log.Global.info
              "okx feed: no channel for %s on these symbols, not connecting"
              (Md.Stream.to_string stream);
            return ()
          | args ->
            let%map ws = connect stream args in
            opened := ws :: !opened))
    with
    | Ok () -> return ()
    | Error exn ->
      let%map () = close_all () in
      raise exn
  in
  let closed =
    Lazy_deferred.create (fun () ->
      let%map () = close_all () in
      Pipe.close trades_w;
      Pipe.close bbo_w;
      Pipe.close l2_w;
      Pipe.close funding_w)
  in
  return
    (module struct
      let trades = trades_r
      let bbo = bbo_r
      let l2 = l2_r
      let funding = funding_r
      let close () = Lazy_deferred.force_exn closed
    end : Md.Feed.S)
;;
