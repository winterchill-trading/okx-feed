(* Minor words allocated per Live_feed message: what [Normalizer.frame] (the scanned path
   for trades, bbo-tbt and books pushes, JSON decode plus conversion for the rest; the
   work [Live_feed] does per websocket frame) allocates on the recorded mainnet minute.
   The largest trades and bbo frame is the subscription ack, still decoded with Yojson;
   the largest books frame is the 400-level snapshot (6 words per level for the event's
   lists). Before the scanner: trades 427, bbo 528, books 9998 per frame and 114688 for
   the snapshot. Funding was 396 per frame before [index-tickers] stopped sorting every
   swap per push. The timing benchmark is in bench/.

   Counts differ by a few words between macOS and Linux CI, so each is printed as the
   pinned value when it is within [tolerance] of it, and as the measured value otherwise. *)

open! Core
open Okx_feed

let words f =
  let before = Gc.minor_words () in
  f ();
  Gc.minor_words () - before
;;

(* Within 2% (at least 8 words) of [expected] prints as [~expected]. *)
let approx ~expected actual =
  let tolerance = Int.max 8 (expected / 50) in
  if abs (actual - expected) <= tolerance
  then sprintf "~%d" expected
  else sprintf "%d (pinned %d +/- %d)" actual expected tolerance
;;

let%expect_test "approx" =
  print_endline (approx ~expected:400 405);
  print_endline (approx ~expected:400 420);
  print_endline (approx ~expected:30_000 30_500);
  [%expect {|
    ~400
    420 (pinned 400 +/- 8)
    ~30000
    |}]
;;

let measure stream =
  let t = Normalizer.create () in
  let per_frame =
    List.map (Fixture.frames stream) ~f:(fun frame ->
      ( words (fun () ->
          ignore
            (Sys.opaque_identity (Normalizer.frame t ~recv_ts:Time_ns.epoch frame)
             : Normalizer.Output.t Or_error.t))
      , String.length frame ))
  in
  let n = List.length per_frame in
  let total = List.sum (module Int) per_frame ~f:fst in
  let bytes = List.sum (module Int) per_frame ~f:snd in
  let max = List.fold per_frame ~init:0 ~f:(fun acc (w, _) -> Int.max acc w) in
  n, total / n, max, bytes / n
;;

let%expect_test "minor words per Live_feed message" =
  (* Funding 375 sits between the macOS (382) and Linux (369) counts; [approx]
     covers both. *)
  List.iter
    Market_data.Stream.
      [ Trades, (22, 209); Bbo, (18, 209); L2, (511, 4844); Funding, (375, 663) ]
    ~f:(fun (stream, (per_frame, max_words)) ->
      let frames, words, max, bytes = measure stream in
      print_s
        [%message
          ""
            (stream : Market_data.Stream.t)
            (frames : int)
            ~words_per_frame:(approx ~expected:per_frame words : string)
            ~max_words:(approx ~expected:max_words max : string)
            ~bytes_per_frame:(bytes : int)]);
  [%expect
    {|
    ((stream Trades) (frames 150) (words_per_frame ~22) (max_words ~209)
     (bytes_per_frame 218))
    ((stream Bbo) (frames 250) (words_per_frame ~18) (max_words ~209)
     (bytes_per_frame 183))
    ((stream L2) (frames 60) (words_per_frame ~511) (max_words ~4844)
     (bytes_per_frame 2322))
    ((stream Funding) (frames 122) (words_per_frame ~375) (max_words ~663)
     (bytes_per_frame 185))
    |}]
;;
