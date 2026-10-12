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
  let module F = (val Live_feed.feed live : Market_data.Feed.S) in
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
    (recv_ts_ms 600)
    |}];
  let%bind () = F.close () in
  Fake_ws.close server
;;
