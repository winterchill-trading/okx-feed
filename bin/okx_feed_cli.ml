open! Core
open Async
module Md = Market_data

let streams_arg =
  Command.Arg_type.create (fun s ->
    String.split s ~on:','
    |> List.filter ~f:(Fn.non String.is_empty)
    |> List.map ~f:Md.Stream.of_string)
;;

let feed_command =
  Command.async
    ~summary:"Print normalized OKX public market data as sexps"
    (let%map_open.Command symbols =
       flag
         "symbol"
         (one_or_more_as_list string)
         ~doc:"SYM OKX instId, e.g. BTC-USDT-SWAP"
     and streams =
       flag
         "streams"
         (optional_with_default [ Md.Stream.Trades ] streams_arg)
         ~doc:"LIST comma-separated: trades,bbo,l2,funding (default trades)"
     and count = flag "count" (optional int) ~doc:"N stop after N events"
     and raw = flag "raw" no_arg ~doc:" also print raw frames to stderr"
     and url =
       flag "url" (optional string) ~doc:"URL websocket endpoint (default mainnet)"
     in
     fun () ->
       let config = Okx_feed.Config.create ?url:(Option.map url ~f:Uri.of_string) () in
       let on_raw =
         Option.some_if raw (fun ~stream ~recv_ts:_ frame ->
           Core.eprintf "%s %s\n%!" (Md.Stream.to_string stream) frame)
       in
       let%bind (module Feed) =
         Okx_feed.Live_feed.create ?on_raw config ~symbols ~streams
       in
       let remaining = ref count in
       let finished = Ivar.create () in
       let print event =
         if not (Ivar.is_full finished)
         then (
           print_s [%sexp (event : Md.Event.t)];
           match !remaining with
           | None -> ()
           | Some n ->
             remaining := Some (n - 1);
             if n <= 1 then Ivar.fill_if_empty finished ())
       in
       let iter pipe ~f =
         don't_wait_for (Pipe.iter_without_pushback pipe ~f:(fun x -> print (f x)))
       in
       iter Feed.trades ~f:(fun x -> Md.Event.Trade x);
       iter Feed.bbo ~f:(fun x -> Md.Event.Bbo x);
       iter Feed.l2 ~f:(fun x -> Md.Event.L2 x);
       iter Feed.funding ~f:(fun x -> Md.Event.Funding x);
       let%bind () = Ivar.read finished in
       let%bind () = Feed.close () in
       Writer.flushed (force Writer.stdout))
;;

let () =
  Command_unix.run
    (Command.group ~summary:"Read-only OKX public market data" [ "feed", feed_command ])
;;
