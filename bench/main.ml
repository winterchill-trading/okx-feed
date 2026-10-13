(* Normalizer.frame per frame on the recorded mainnet minute (test/fixtures).

   [trades], [bbo] and [funding] cycle through their recorded frames, one frame per run,
   on one normalizer (funding needs its merged state). Book deltas only apply in sequence,
   so [l2 replay] is the whole book recording per run: a fresh normalizer, the ack, the
   400-level snapshot and 58 deltas (60 frames). [l2 snapshot] is the snapshot alone. The
   [yojson] rows run [Normalizer.frame_reference], the decoder the scanner replaced. *)

open! Core
open Core_bench
open Okx_feed

(* Raw minute lines are [<recv_ts> <frame>]. *)
let frames s =
  String.split_lines s
  |> List.filter_map ~f:(fun line -> Option.map (String.lsplit2 line ~on:' ') ~f:snd)
;;

let run ?(frame_fn = Normalizer.frame) t frame =
  ignore
    (Sys.opaque_identity (frame_fn t ~recv_ts:Time_ns.epoch frame)
     : Normalizer.Output.t Or_error.t)
;;

let per_frame ?frame_fn name text =
  let frames = Array.of_list (frames text) in
  let t = Normalizer.create () in
  let i = ref 0 in
  Bench.Test.create ~name (fun () ->
    let frame = frames.(!i) in
    i := (!i + 1) % Array.length frames;
    run ?frame_fn t frame)
;;

let l2_replay ?frame_fn name =
  let frames = frames Frames.l2 in
  Bench.Test.create ~name (fun () ->
    let t = Normalizer.create () in
    List.iter frames ~f:(run ?frame_fn t))
;;

(* The 400-level snapshot alone on a fresh normalizer: [l2 replay] minus this is the cost
   of the ack and the 58 deltas. *)
let l2_snapshot () =
  let snapshot =
    List.find_exn (frames Frames.l2) ~f:(String.is_substring ~substring:{|"snapshot"|})
  in
  Bench.Test.create ~name:"l2 snapshot" (fun () -> run (Normalizer.create ()) snapshot)
;;

let reference = Normalizer.frame_reference

let () =
  Command_unix.run
    (Bench.make_command
       [ per_frame "trades" Frames.trades
       ; per_frame "bbo" Frames.bbo
       ; per_frame "funding" Frames.funding
       ; l2_snapshot ()
       ; l2_replay "l2 replay"
       ; per_frame ~frame_fn:reference "trades yojson" Frames.trades
       ; per_frame ~frame_fn:reference "bbo yojson" Frames.bbo
       ; l2_replay ~frame_fn:reference "l2 replay yojson"
       ])
;;
