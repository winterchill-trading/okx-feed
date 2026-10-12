(* [Live_feed] against a scripted local websocket server. *)

open! Core
open Async
open Okx_feed

let trade =
  {|{"arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"data":[{"instId":"BTC-USDT-SWAP","tradeId":"2988536030","px":"82932.5","sz":"0.01","side":"sell","ts":"1791817761147","count":"1","source":"0","seqId":1}]}|}
;;

let%expect_test "a malformed frame is counted and skipped" =
  Log.Global.set_output [];
  let%bind server = Fake_ws.start () in
  let%bind live =
    Live_feed.start
      (Fake_ws.config server)
      ~symbols:[ "BTC-USDT-SWAP" ]
      ~streams:[ Trades ]
  in
  let module F = (val Live_feed.feed live : Market_data.Feed.S) in
  let%bind (_ : bool) =
    Fake_ws.wait_until (fun () -> not (List.is_empty (Fake_ws.received server)))
  in
  print_s [%sexp (Fake_ws.received server : string list)];
  [%expect
    {| ("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"trades\",\"instId\":\"BTC-USDT-SWAP\"}]}") |}];
  Fake_ws.send
    server
    {|{"event":"subscribe","arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"connId":"a1"}|};
  Fake_ws.send server {|{"arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"data":[{|};
  Fake_ws.send server trade;
  let%bind trade = Pipe.read F.trades in
  (match trade with
   | `Ok trade -> print_s [%sexp (trade.trade_id : string)]
   | `Eof -> print_endline "eof");
  print_s [%sexp (Live_feed.stats live : Live_feed.Stats.t)];
  [%expect {|
    2988536030
    ((frames 3) (parse_errors 1) (reconnects 0))
    |}];
  let%bind () = F.close () in
  Fake_ws.close server
;;

let print_gaps (gaps : Market_data.Gap.t Pipe.Reader.t) =
  match Pipe.read_now' gaps with
  | `Nothing_available -> print_endline "no gap"
  | `Eof -> print_endline "gaps closed"
  | `Ok gaps ->
    Queue.iter gaps ~f:(fun (gap : Market_data.Gap.t) ->
      print_s
        [%message
          "gap"
            ~recv_ts_ms:(Time_ns.to_int_ns_since_epoch gap.recv_ts / 1_000_000 : int)
            ~instrument:
              (Option.map gap.instrument ~f:Market_data.Instrument.to_string
               : string option)
            ~stream:(gap.stream : Market_data.Stream.t option)
            ~reason:(gap.reason : Market_data.Gap.Reason.t)])
;;

let%expect_test "reconnects on a synthetic clock and resubscribes" =
  Log.Global.set_output [];
  let%bind server = Fake_ws.start () in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind live =
    Live_feed.start
      ~time_source:(Time_source.read_only clock)
      (Fake_ws.config server)
      ~symbols:[ "BTC-USDT-SWAP" ]
      ~streams:[ Trades ]
  in
  let module F = (val Live_feed.feed_with_gaps live : Market_data.Feed.With_gaps.S) in
  let subscribes () =
    List.count (Fake_ws.received server) ~f:(String.is_substring ~substring:"subscribe")
  in
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> subscribes () = 1) in
  let%bind () = Fake_ws.drop server in
  (* The first backoff is 0.5s with 20% jitter: nothing before 0.4s, a new connection by
     0.6s. Real I/O is given time to happen at each step. *)
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 50) in
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_ms 390) in
  let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 50) in
  print_s [%message "after 0.39s" ~connections:(Fake_ws.connections server : int)];
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_ms 210) in
  let%bind (_ : bool) = Fake_ws.wait_until (fun () -> subscribes () = 2) in
  print_s
    [%message
      "after 0.6s"
        ~connections:(Fake_ws.connections server : int)
        ~subscribes:(subscribes () : int)
        ~stats:(Live_feed.stats live : Live_feed.Stats.t)];
  (* The gap is written when the new connection is up, before any of its frames. *)
  print_gaps F.gaps;
  Fake_ws.send server trade;
  let%bind trade = Pipe.read F.trades in
  (match trade with
   | `Ok trade ->
     print_s
       [%message
         "" ~recv_ts_ms:(Time_ns.to_int_ns_since_epoch trade.recv_ts / 1_000_000 : int)]
   | `Eof -> print_endline "eof");
  [%expect
    {|
    ("after 0.39s" (connections 1))
    ("after 0.6s" (connections 2) (subscribes 2)
     (stats ((frames 0) (parse_errors 0) (reconnects 1))))
    (gap (recv_ts_ms 600) (instrument ()) (stream (Trades)) (reason Resync))
    (recv_ts_ms 600)
    |}];
  print_gaps F.gaps;
  [%expect {| no gap |}];
  let%bind () = F.close () in
  Fake_ws.close server
;;

let book ?(action = "update") ~prev ~seq ?(bids = "[]") ?(asks = "[]") () =
  sprintf
    {|{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"%s","data":[{"asks":%s,"bids":%s,"ts":"1597026383%03d","checksum":0,"prevSeqId":%d,"seqId":%d}]}|}
    action
    asks
    bids
    seq
    prev
    seq
;;

let%expect_test "a book sequence gap reports a gap and resubscribes" =
  Log.Global.set_output [];
  let%bind server = Fake_ws.start () in
  let clock = Time_source.create ~now:Time_ns.epoch () in
  let%bind live =
    Live_feed.start
      ~time_source:(Time_source.read_only clock)
      (Fake_ws.config server)
      ~symbols:[ "BTC-USDT-SWAP" ]
      ~streams:[ L2 ]
  in
  let module F = (val Live_feed.feed_with_gaps live : Market_data.Feed.With_gaps.S) in
  let%bind (_ : bool) =
    Fake_ws.wait_until (fun () -> not (List.is_empty (Fake_ws.received server)))
  in
  let read_l2 () =
    match%map Pipe.read F.l2 with
    | `Ok (l2 : Market_data.L2_update.t) ->
      (* Gaps written before this event are already in their pipe. *)
      print_gaps F.gaps;
      print_s [%sexp (l2.kind : Market_data.L2_update.Kind.t)]
    | `Eof -> print_endline "eof"
  in
  let level = {|[["8476.97","1","0","1"]]|} in
  Fake_ws.send
    server
    (book
       ~action:"snapshot"
       ~prev:(-1)
       ~seq:10
       ~bids:level
       ~asks:{|[["8477","7","0","2"]]|}
       ());
  let%bind () = read_l2 () in
  [%expect {|
    no gap
    Snapshot
    |}];
  let%bind () = Time_source.advance_by_alarms_by clock (Time_ns.Span.of_int_ms 100) in
  (* [prevSeqId] 12 does not follow 10: the book is dropped and the channel resubscribed. *)
  Fake_ws.send server (book ~prev:12 ~seq:13 ~bids:level ());
  let%bind (_ : bool) =
    Fake_ws.wait_until (fun () -> List.length (Fake_ws.received server) = 3)
  in
  print_s [%sexp (List.tl_exn (Fake_ws.received server) : string list)];
  [%expect
    {|
    ("{\"op\":\"unsubscribe\",\"args\":[{\"channel\":\"books\",\"instId\":\"BTC-USDT-SWAP\"}]}"
     "{\"op\":\"subscribe\",\"args\":[{\"channel\":\"books\",\"instId\":\"BTC-USDT-SWAP\"}]}")
    |}];
  Fake_ws.send
    server
    (book
       ~action:"snapshot"
       ~prev:(-1)
       ~seq:20
       ~bids:level
       ~asks:{|[["8477","7","0","2"]]|}
       ());
  let%bind () = read_l2 () in
  [%expect
    {|
    (gap (recv_ts_ms 100) (instrument (okx:BTC-USDT-SWAP)) (stream (L2))
     (reason Resync))
    Snapshot
    |}];
  print_s [%sexp (Live_feed.stats live : Live_feed.Stats.t)];
  [%expect {| ((frames 3) (parse_errors 0) (reconnects 0)) |}];
  let%bind () = F.close () in
  let%bind () = Fake_ws.close server in
  print_gaps F.gaps;
  [%expect {| gaps closed |}];
  return ()
;;
