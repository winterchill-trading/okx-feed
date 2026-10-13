(* The allocation-free readers on hand-written frames, and [Scan.decimal] against
   [Market_data.Price.of_string]. *)

open! Core
open Okx_feed

let sub s ~pos ~len = String.sub s ~pos ~len

let%expect_test "trade" =
  let frame =
    {|{"arg":{"channel":"trades","instId":"BTC-USDT-SWAP"},"data":[{"instId":"BTC-USDT-SWAP","tradeId":"2989121448","px":"82580.9","sz":"0.06","side":"sell","ts":"1791824024450","count":"1","source":"0","seqId":345546259997}]}|}
  in
  let t = Scan.create_trade () in
  let ok = Scan.trade frame t in
  print_s
    [%message
      (ok : bool)
        ~inst:(sub frame ~pos:t.inst_pos ~len:t.inst_len : string)
        ~trade_id:(sub frame ~pos:t.trade_id_pos ~len:t.trade_id_len : string)
        (t.px : int)
        (t.sz : int)
        (t.buy : bool)
        (t.ts : int)];
  [%expect
    {|
    ((ok true) (inst BTC-USDT-SWAP) (trade_id 2989121448) (t.px 8258090000000)
     (t.sz 6000000) (t.buy false) (t.ts 1791824024450))
    |}]
;;

let%expect_test "book" =
  let frame =
    {|{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"update","data":[{"asks":[["82576.9","1185.58","0","46"],["82578.3","0","0","0"]],"bids":[],"ts":"1791824026706","checksum":0,"seqId":345546265848,"prevSeqId":345546265595}]}|}
  in
  let b = Scan.create_book () in
  let ok = Scan.book frame b in
  let side (l : Scan.Levels.t) = List.init l.n ~f:(fun i -> l.px.(i), l.sz.(i)) in
  print_s
    [%message
      (ok : bool)
        ~channel:(sub frame ~pos:b.channel_pos ~len:b.channel_len : string)
        ~inst:(sub frame ~pos:b.inst_pos ~len:b.inst_len : string)
        (b.snapshot : bool)
        (b.ts : int)
        (b.seq_id : int)
        (b.prev_seq_id : int)
        ~asks:(side b.asks : (int * int) list)
        ~bids:(side b.bids : (int * int) list)];
  [%expect
    {|
    ((ok true) (channel books) (inst BTC-USDT-SWAP) (b.snapshot false)
     (b.ts 1791824026706) (b.seq_id 345546265848) (b.prev_seq_id 345546265595)
     (asks ((8257690000000 118558000000) (8257830000000 0))) (bids ()))
    |}]
;;

let%expect_test "shapes left to the Yojson decoder" =
  let trade = Scan.create_trade () in
  let book = Scan.create_book () in
  List.iter
    [ (* two entries *)
      {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X","tradeId":"1","px":"1","sz":"1","side":"buy","ts":"1"},{"instId":"X","tradeId":"2","px":"1","sz":"1","side":"buy","ts":"1"}]}|}
    ; (* escape in a string *)
      {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X\u0041","tradeId":"1","px":"1","sz":"1","side":"buy","ts":"1"}]}|}
    ; (* arg fields reordered *)
      {|{"arg":{"instId":"X","channel":"trades"},"data":[{"instId":"X","tradeId":"1","px":"1","sz":"1","side":"buy","ts":"1"}]}|}
    ; (* unknown side, exponent, missing field *)
      {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X","tradeId":"1","px":"1","sz":"1","side":"short","ts":"1"}]}|}
    ; {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X","tradeId":"1","px":"1e3","sz":"1","side":"buy","ts":"1"}]}|}
    ; {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X","tradeId":"1","sz":"1","side":"buy","ts":"1"}]}|}
    ; (* trailing whitespace *)
      {|{"arg":{"channel":"trades","instId":"X"},"data":[{"instId":"X","tradeId":"1","px":"1","sz":"1","side":"buy","ts":"1"}]} |}
    ; (* books without an action (books5), a level of one string, no prevSeqId *)
      {|{"arg":{"channel":"books5","instId":"X"},"data":[{"asks":[["1","1","0","1"]],"bids":[],"ts":"1"}]}|}
    ; {|{"arg":{"channel":"books","instId":"X"},"action":"update","data":[{"asks":[["1"]],"bids":[],"ts":"1","seqId":2,"prevSeqId":1}]}|}
    ; {|{"arg":{"channel":"books","instId":"X"},"action":"update","data":[{"asks":[],"bids":[],"ts":"1","seqId":2}]}|}
    ; {|{"event":"subscribe","arg":{"channel":"trades","instId":"X"},"connId":"1"}|}
    ; "pong"
    ; ""
    ]
    ~f:(fun frame ->
      print_s
        [%message
          ""
            ~trade:(Scan.trade frame trade : bool)
            ~bbo:(Scan.bbo frame book : bool)
            ~book:(Scan.book frame book : bool)]);
  [%expect
    {|
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    ((trade false) (bbo false) (book false))
    |}]
;;

(* Whenever [Scan.decimal] reads a value, [Price.of_string] reads the same one. *)
let%test_unit "decimal agrees with Price.of_string" =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    let digits n = String.gen_with_length n Char.gen_digit in
    let%bind int_part = Int.gen_incl 0 12 >>= digits in
    let%bind frac = Int.gen_incl 0 12 >>= digits in
    let%bind dot = Bool.quickcheck_generator in
    let%bind junk = Quickcheck.Generator.of_list [ ""; "x"; "-"; "."; "e5" ] in
    return (int_part ^ (if dot then "." else "") ^ frac ^ junk)
  in
  Quickcheck.test gen ~sexp_of:String.sexp_of_t ~trials:20_000 ~f:(fun s ->
    let scanned = Scan.decimal (s ^ {|"|}) 0 in
    if scanned >= 0
    then
      [%test_result: int]
        scanned
        ~expect:(Market_data.Price.to_units (Market_data.Price.of_string s)))
;;

let%expect_test "decimal" =
  List.iter
    [ "0"; "82580.9"; "0.06"; "1.123456789"; "0007"; "1."; ".5"; "-1"; "12345678901"; "" ]
    ~f:(fun s -> printf "%-12s %d\n" s (Scan.decimal (s ^ {|"|}) 0));
  [%expect
    {|
    0            0
    82580.9      8258090000000
    0.06         6000000
    1.123456789  112345678
    0007         700000000
    1.           -1
    .5           -1
    -1           -1
    12345678901  -1
                 -1
    |}]
;;

let%expect_test "minor words per scan" =
  let frame name =
    List.find_exn (Fixture.frames name) ~f:(String.is_substring ~substring:{|"data"|})
  in
  let trades = frame Trades
  and bbo = frame Bbo
  and books =
    List.find_exn (Fixture.frames L2) ~f:(String.is_substring ~substring:{|"update"|})
  in
  let trade = Scan.create_trade ()
  and book = Scan.create_book () in
  let words f =
    let before = Gc.minor_words () in
    let ok = f () in
    ok, Gc.minor_words () - before
  in
  print_s
    [%message
      ""
        ~trade:(words (fun () -> Scan.trade trades trade) : bool * int)
        ~bbo:(words (fun () -> Scan.bbo bbo book) : bool * int)
        ~book:(words (fun () -> Scan.book books book) : bool * int)];
  [%expect {| ((trade (true 0)) (bbo (true 0)) (book (true 0))) |}]
;;
