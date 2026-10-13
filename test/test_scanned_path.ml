(* [Normalizer.frame] (scanned where [Scan] reads the frame) against
   [Normalizer.frame_reference] (always Yojson): identical output, frame by frame, on every
   recorded frame and on hand-written frames covering the sequencing branches. *)

open! Core
open Okx_feed

type outcome = Normalizer.Output.t Or_error.t [@@deriving sexp_of]

(* Runs both paths on their own normalizer; prints the first difference. Returns how many
   frames the scanner read. *)
let compare_paths frames =
  let fast = Normalizer.create ()
  and reference = Normalizer.create () in
  let trade = Scan.create_trade ()
  and book = Scan.create_book () in
  List.fold frames ~init:0 ~f:(fun scanned frame ->
    let recv_ts = Time_ns.epoch in
    let a = Normalizer.frame fast ~recv_ts frame
    and b = Normalizer.frame_reference reference ~recv_ts frame in
    if not (Sexp.equal (sexp_of_outcome a) (sexp_of_outcome b))
    then
      print_s [%message "paths differ" frame ~scanned:(a : outcome) ~reference:(b : outcome)];
    if Scan.trade frame trade || Scan.bbo frame book || Scan.book frame book
    then scanned + 1
    else scanned)
;;

let%expect_test "every recorded frame" =
  List.iter Fixture.streams ~f:(fun stream ->
    let frames = Fixture.frames stream in
    let scanned = compare_paths frames in
    print_s
      [%message
        "" (stream : Market_data.Stream.t) ~frames:(List.length frames : int) (scanned : int)]);
  [%expect
    {|
    ((stream Trades) (frames 150) (scanned 149))
    ((stream Bbo) (frames 250) (scanned 249))
    ((stream L2) (frames 60) (scanned 59))
    ((stream Funding) (frames 122) (scanned 0))
    |}]
;;

let book ~inst ~action ~asks ~bids ~seq ~prev =
  sprintf
    {|{"arg":{"channel":"books","instId":"%s"},"action":"%s","data":[{"asks":[%s],"bids":[%s],"ts":"1791824026706","checksum":0,"seqId":%d,"prevSeqId":%d}]}|}
    inst
    action
    asks
    bids
    seq
    prev
;;

let%expect_test "sequencing, unsorted snapshots and several symbols" =
  let a = {|["100.5","1","0","1"]|}
  and b = {|["100.4","2","0","1"]|}
  and c = {|["99","3","0","2"]|} in
  let frames =
    [ (* update before any snapshot: dropped *)
      book ~inst:"BTC-USDT-SWAP" ~action:"update" ~asks:a ~bids:c ~seq:5 ~prev:4
    ; (* snapshot with both sides out of order *)
      book
        ~inst:"BTC-USDT-SWAP"
        ~action:"snapshot"
        ~asks:(String.concat ~sep:"," [ a; b ])
        ~bids:(String.concat ~sep:"," [ c; b ])
        ~seq:10
        ~prev:(-1)
    ; book ~inst:"ETH-USDT-SWAP" ~action:"snapshot" ~asks:a ~bids:c ~seq:7 ~prev:(-1)
    ; (* heartbeat *)
      book ~inst:"BTC-USDT-SWAP" ~action:"update" ~asks:"" ~bids:"" ~seq:10 ~prev:10
    ; book ~inst:"BTC-USDT-SWAP" ~action:"update" ~asks:b ~bids:"" ~seq:11 ~prev:10
    ; book ~inst:"ETH-USDT-SWAP" ~action:"update" ~asks:"" ~bids:b ~seq:8 ~prev:7
    ; (* gap *)
      book ~inst:"BTC-USDT-SWAP" ~action:"update" ~asks:b ~bids:"" ~seq:14 ~prev:12
    ; (* sequence reset after maintenance *)
      book ~inst:"ETH-USDT-SWAP" ~action:"update" ~asks:a ~bids:"" ~seq:3 ~prev:8
    ; {|{"arg":{"channel":"bbo-tbt","instId":"ETH-USDT-SWAP"},"data":[{"asks":[],"bids":[["1","1","0","1"]],"ts":"1"}]}|}
    ; {|{"arg":{"channel":"trades","instId":"ETH-USDT-SWAP"},"data":[{"instId":"ETH-USDT-SWAP","tradeId":"7","px":"2500.01","sz":"3","side":"buy","ts":"1791824024450"}]}|}
    ; {|{"arg":{"channel":"trades","instId":"ETH-USDT-SWAP"},"data":[{"instId":"ETH-USDT-SWAP","tradeId":"8","px":"2500.01","sz":"3","side":"short","ts":"1791824024450"}]}|}
    ]
  in
  let scanned = compare_paths frames in
  print_s [%message (scanned : int)];
  [%expect {| (scanned 10) |}]
;;
