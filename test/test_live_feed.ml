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
