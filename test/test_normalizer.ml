open! Core
open Okx_feed

let () = Async.Log.Global.set_output []
let recv_ts = Time_ns.of_int_ns_since_epoch 1_700_000_000_000_000_000

(* Time_ns sexps use the local zone; print milliseconds since the epoch instead. *)
let rec rewrite_times (sexp : Sexp.t) : Sexp.t =
  match sexp with
  | List [ Atom (("exch_ts" | "recv_ts" | "next_funding_time") as field); time ] ->
    let ms = Time_ns.to_int_ns_since_epoch (Time_ns.t_of_sexp time) / 1_000_000 in
    List [ Atom field; Atom (Int.to_string ms) ]
  | List l -> List (List.map l ~f:rewrite_times)
  | Atom _ -> sexp
;;

let feed normalizer frame =
  match Normalizer.frame normalizer ~recv_ts frame with
  | Error _ -> print_endline "error"
  | Ok { events; resubscribe } ->
    List.iter events ~f:(fun event ->
      print_s (rewrite_times [%sexp (event : Market_data.Event.t)]));
    if not (List.is_empty resubscribe)
    then print_s [%message "resubscribe" (resubscribe : Wire.Arg.t list)]
;;

let%expect_test "trades" =
  let t = Normalizer.create () in
  feed
    t
    {|{"arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"data":[
        {"instId":"BTC-USDT-SWAP","tradeId":"130639474","px":"42219.9","sz":"12",
         "side":"buy","ts":"1630048897897","count":"3","source":"0","seqId":1234},
        {"instId":"BTC-USDT-SWAP","tradeId":"130639475","px":"42219.8","sz":"0.5",
         "side":"sell","ts":"1630048897898","count":"1","source":"0","seqId":1235}]}|};
  [%expect
    {|
    (Trade
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1630048897897)
      (recv_ts 1700000000000) (price 42219.9) (size 12) (side Buy)
      (trade_id 130639474)))
    (Trade
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1630048897898)
      (recv_ts 1700000000000) (price 42219.8) (size 0.5) (side Sell)
      (trade_id 130639475)))
    |}]
;;

let%expect_test "bbo-tbt" =
  let t = Normalizer.create () in
  feed
    t
    {|{"arg":{"channel":"bbo-tbt","instId":"BCH-USDT-SWAP"},"data":[
        {"asks":[["111.06","55154","0","2"]],"bids":[["111.05","57745","0","2"]],
         "ts":"1670324386802","seqId":363996337}]}|};
  [%expect
    {|
    (Bbo
     ((instrument ((venue Okx) (symbol BCH-USDT-SWAP))) (exch_ts 1670324386802)
      (recv_ts 1700000000000) (bid_price 111.05) (bid_size 57745)
      (ask_price 111.06) (ask_size 55154)))
    |}];
  (* One side empty: nothing. *)
  feed
    t
    {|{"arg":{"channel":"bbo-tbt","instId":"BCH-USDT-SWAP"},"data":[
        {"asks":[],"bids":[["111.05","57745","0","2"]],"ts":"1670324386803","seqId":1}]}|};
  [%expect {| |}]
;;

let book ?(action = "update") ~prev ~seq ?(bids = "[]") ?(asks = "[]") () =
  sprintf
    {|{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"%s","data":[
        {"asks":%s,"bids":%s,"ts":"1597026383%03d","checksum":0,"prevSeqId":%d,"seqId":%d}]}|}
    action
    asks
    bids
    seq
    prev
    seq
;;

let%expect_test "books: snapshot, deltas, heartbeat, sequence reset" =
  let t = Normalizer.create () in
  (* Updates before the first snapshot are dropped. *)
  feed t (book ~prev:9 ~seq:10 ~bids:{|[["8476.97","1","0","1"]]|} ());
  [%expect {| |}];
  feed
    t
    (book
       ~action:"snapshot"
       ~prev:(-1)
       ~seq:10
       ~asks:{|[["8477","7","0","2"],["8476.98","415","0","13"]]|}
       ~bids:{|[["8475.55","101","0","1"],["8476.97","256","0","12"]]|}
       ());
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1597026383010)
      (recv_ts 1700000000000) (kind Snapshot)
      (bids (((price 8476.97) (size 256)) ((price 8475.55) (size 101))))
      (asks (((price 8476.98) (size 415)) ((price 8477) (size 7))))))
    |}];
  feed t (book ~prev:10 ~seq:15 ~asks:{|[["8476.98","0","0","0"]]|} ());
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1597026383015)
      (recv_ts 1700000000000) (kind Delta) (bids ())
      (asks (((price 8476.98) (size 0))))))
    |}];
  (* Heartbeat: same seqId, no levels. *)
  feed t (book ~prev:15 ~seq:15 ());
  [%expect {| |}];
  (* Sequence reset after maintenance: seqId < prevSeqId but prevSeqId joins. *)
  feed t (book ~prev:15 ~seq:3 ~bids:{|[["8476.5","2","0","1"]]|} ());
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1597026383003)
      (recv_ts 1700000000000) (kind Delta) (bids (((price 8476.5) (size 2))))
      (asks ())))
    |}];
  feed t (book ~prev:3 ~seq:5 ~bids:{|[["8476.5","0","0","0"]]|} ());
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1597026383005)
      (recv_ts 1700000000000) (kind Delta) (bids (((price 8476.5) (size 0))))
      (asks ())))
    |}]
;;

let%expect_test "books: a gap resubscribes and waits for a new snapshot" =
  let t = Normalizer.create () in
  feed t (book ~action:"snapshot" ~prev:(-1) ~seq:10 ~bids:{|[["100","1","0","1"]]|} ());
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1597026383010)
      (recv_ts 1700000000000) (kind Snapshot) (bids (((price 100) (size 1))))
      (asks ())))
    |}];
  feed t (book ~prev:11 ~seq:12 ~bids:{|[["100","2","0","1"]]|} ());
  [%expect {| (resubscribe (resubscribe (((channel books) (inst_id BTC-USDT-SWAP))))) |}];
  (* The book is dropped: even an update joining the old sequence is ignored. *)
  feed t (book ~prev:10 ~seq:13 ~bids:{|[["100","3","0","1"]]|} ());
  [%expect {| |}];
  feed t (book ~action:"snapshot" ~prev:(-1) ~seq:20 ~bids:{|[["101","1","0","1"]]|} ());
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1597026383020)
      (recv_ts 1700000000000) (kind Snapshot) (bids (((price 101) (size 1))))
      (asks ())))
    |}];
  feed t (book ~prev:20 ~seq:21 ~asks:{|[["102","1","0","1"]]|} ());
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1597026383021)
      (recv_ts 1700000000000) (kind Delta) (bids ())
      (asks (((price 102) (size 1))))))
    |}];
  (* [reset] (after a reconnect) also drops the book. *)
  Normalizer.reset t;
  feed t (book ~prev:21 ~seq:22 ~asks:{|[["102","2","0","1"]]|} ());
  [%expect {| |}]
;;

let%expect_test "books5: every push is a snapshot" =
  let t = Normalizer.create () in
  feed
    t
    {|{"arg":{"channel":"books5","instId":"BCH-USDT-SWAP"},"data":[
        {"asks":[["111.07","53276","0","2"],["111.06","55154","0","2"]],
         "bids":[["111.05","57745","0","2"]],"instId":"BCH-USDT-SWAP",
         "ts":"1670324386802","seqId":363996337}]}|};
  [%expect
    {|
    (L2
     ((instrument ((venue Okx) (symbol BCH-USDT-SWAP))) (exch_ts 1670324386802)
      (recv_ts 1700000000000) (kind Snapshot)
      (bids (((price 111.05) (size 57745))))
      (asks (((price 111.06) (size 55154)) ((price 111.07) (size 53276))))))
    |}]
;;

let funding_rate ~rate ~time ~ts =
  sprintf
    {|{"arg":{"channel":"funding-rate","instId":"BTC-USDT-SWAP"},"data":[
        {"formulaType":"withRate","fundingRate":"%s","fundingTime":"%s","impactValue":"",
         "instId":"BTC-USDT-SWAP","instType":"SWAP","interestRate":"0.0001",
         "method":"current_period","maxFundingRate":"0.00375","minFundingRate":"-0.00375",
         "nextFundingRate":"","nextFundingTime":"1700755200000","premium":"0.0001",
         "settFundingRate":"0.0001","settState":"settled","ts":"%s"}]}|}
    rate
    time
    ts
;;

let mark ~px ~ts =
  sprintf
    {|{"arg":{"channel":"mark-price","instId":"BTC-USDT-SWAP"},"data":[
        {"instType":"SWAP","instId":"BTC-USDT-SWAP","markPx":"%s","ts":"%s"}]}|}
    px
    ts
;;

let index ~inst_id ~px ~ts =
  sprintf
    {|{"arg":{"channel":"index-tickers","instId":"%s"},"data":[
        {"instId":"%s","idxPx":"%s","high24h":"1","low24h":"1","open24h":"1",
         "sodUtc0":"1","sodUtc8":"1","ts":"%s"}]}|}
    inst_id
    inst_id
    px
    ts
;;

let%expect_test "funding: rate, mark and index merged" =
  let t = Normalizer.create () in
  feed t (funding_rate ~rate:"0.0001875" ~time:"1700726400000" ~ts:"1700724675402");
  feed t (mark ~px:"42310.6" ~ts:"1700724675500");
  (* Another index is not this swap's. *)
  feed t (index ~inst_id:"ETH-USDT" ~px:"2000" ~ts:"1700724675550");
  [%expect {| |}];
  feed t (index ~inst_id:"BTC-USDT" ~px:"42300.1" ~ts:"1700724675600");
  [%expect
    {|
    (Funding
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1700724675600)
      (recv_ts 1700000000000) (rate 0.0001875) (next_funding_time 1700726400000)
      (mark_price 42310.6) (index_price 42300.1)))
    |}];
  (* Unchanged values emit nothing. *)
  feed t (mark ~px:"42310.6" ~ts:"1700724675700");
  feed t (index ~inst_id:"BTC-USDT" ~px:"42300.1" ~ts:"1700724675800");
  [%expect {| |}];
  feed t (mark ~px:"42311" ~ts:"1700724675900");
  [%expect
    {|
    (Funding
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1700724675900)
      (recv_ts 1700000000000) (rate 0.0001875) (next_funding_time 1700726400000)
      (mark_price 42311) (index_price 42300.1)))
    |}];
  feed t (funding_rate ~rate:"-0.00002" ~time:"1700755200000" ~ts:"1700726401000");
  [%expect
    {|
    (Funding
     ((instrument ((venue Okx) (symbol BTC-USDT-SWAP))) (exch_ts 1700726401000)
      (recv_ts 1700000000000) (rate -2E-05) (next_funding_time 1700755200000)
      (mark_price 42311) (index_price 42300.1)))
    |}]
;;

let%expect_test "acks, pongs, notices, unknown channels" =
  let t = Normalizer.create () in
  List.iter
    ~f:(feed t)
    [ "pong"
    ; {|{"id":"1","event":"subscribe","arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"connId":"a4d3ae55"}|}
    ; {|{"event":"unsubscribe","arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"connId":"d0b44253"}|}
    ; {|{"event":"notice","code":"64008","msg":"The connection will soon be closed for a service upgrade. Please reconnect.","connId":"a4d3ae55"}|}
    ; {|{"arg":{"channel":"open-interest","instId":"BTC-USDT-SWAP"},"data":[{"oi":"1"}]}|}
    ];
  [%expect {| |}]
;;

let%expect_test "bad frames are errors, not exceptions" =
  let t = Normalizer.create () in
  let show frame =
    match Normalizer.frame t ~recv_ts frame with
    | Ok _ -> print_endline "ok"
    | Error _ -> print_endline "error"
  in
  List.iter
    ~f:show
    [ "not json"
    ; "[1,2]"
    ; {|{"foo":1}|}
    ; {|{"arg":{"channel":"trades","instId":"X"}}|}
    ; {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X"}]}|}
    ; {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X","tradeId":"1","px":"1","sz":"1","side":"up","ts":"1"}]}|}
    ; {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X","tradeId":"1","px":"abc","sz":"1","side":"buy","ts":"1"}]}|}
    ; {|{"arg":{"channel":"books","instId":"X"},"action":"snapshot","data":[{"asks":[["1"]],"bids":[],"ts":"1","prevSeqId":-1,"seqId":1}]}|}
    ; {|{"arg":{"channel":"books","instId":"X"},"action":"replace","data":[]}|}
    ];
  [%expect
    {|
    error
    error
    error
    error
    error
    error
    error
    error
    error
    |}];
  (* An error event carries code and message. *)
  (match
     Normalizer.frame
       t
       ~recv_ts
       {|{"id":"1512","event":"error","code":"60018","msg":"Wrong URL or channel:books, instId:FOO doesn't exist.","connId":"a4d3ae55"}|}
   with
   | Ok _ -> print_endline "ok"
   | Error error -> print_s [%sexp (error : Error.t)]);
  [%expect
    {|
    ("OKX error event" (code (60018))
     (msg ("Wrong URL or channel:books, instId:FOO doesn't exist.")) (arg ()))
    |}]
;;

let%expect_test "subscriptions" =
  let print stream =
    print_endline
      (Wire.Request.to_string
         Subscribe
         (Live_feed.args stream ~symbols:[ "BTC-USDT-SWAP"; "BTC-USDT"; "ETH-USD-SWAP" ]))
  in
  List.iter [ Market_data.Stream.Trades; Bbo; L2; Funding ] ~f:print;
  [%expect
    {|
    {"op":"subscribe","args":[{"channel":"trades","instId":"BTC-USDT-SWAP"},{"channel":"trades","instId":"BTC-USDT"},{"channel":"trades","instId":"ETH-USD-SWAP"}]}
    {"op":"subscribe","args":[{"channel":"bbo-tbt","instId":"BTC-USDT-SWAP"},{"channel":"bbo-tbt","instId":"BTC-USDT"},{"channel":"bbo-tbt","instId":"ETH-USD-SWAP"}]}
    {"op":"subscribe","args":[{"channel":"books","instId":"BTC-USDT-SWAP"},{"channel":"books","instId":"BTC-USDT"},{"channel":"books","instId":"ETH-USD-SWAP"}]}
    {"op":"subscribe","args":[{"channel":"funding-rate","instId":"BTC-USDT-SWAP"},{"channel":"funding-rate","instId":"ETH-USD-SWAP"},{"channel":"mark-price","instId":"BTC-USDT-SWAP"},{"channel":"mark-price","instId":"ETH-USD-SWAP"},{"channel":"index-tickers","instId":"BTC-USDT"},{"channel":"index-tickers","instId":"ETH-USD"}]}
    |}];
  print_endline (Normalizer.index_of "BTC-USD-250328");
  [%expect {| BTC-USD |}]
;;
