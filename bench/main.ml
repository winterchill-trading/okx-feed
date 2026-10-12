(* Normalizer.frame per frame on the recorded mainnet minute (test/fixtures).

   [trades], [bbo] and [funding] cycle through their recorded frames, one frame per run,
   on one normalizer (funding needs its merged state). Book deltas only apply in sequence,
   so [l2 replay] is the whole book recording per run: a fresh normalizer, the ack, the
   400-level snapshot and 58 deltas (60 frames). *)

open! Core
open Core_bench
open Okx_feed

(* Raw minute lines are [<recv_ts> <frame>]. *)
let frames s =
  String.split_lines s
  |> List.filter_map ~f:(fun line -> Option.map (String.lsplit2 line ~on:' ') ~f:snd)
;;

let run t frame =
  ignore
    (Sys.opaque_identity (Normalizer.frame t ~recv_ts:Time_ns.epoch frame)
     : Normalizer.Output.t Or_error.t)
;;

let per_frame name text =
  let frames = Array.of_list (frames text) in
  let t = Normalizer.create () in
  let i = ref 0 in
  Bench.Test.create ~name (fun () ->
    let frame = frames.(!i) in
    i := (!i + 1) % Array.length frames;
    run t frame)
;;

let l2_replay () =
  let frames = frames Frames.l2 in
  Bench.Test.create ~name:"l2 replay" (fun () ->
    let t = Normalizer.create () in
    List.iter frames ~f:(run t))
;;

let () =
  Command_unix.run
    (Bench.make_command
       [ per_frame "trades" Frames.trades
       ; per_frame "bbo" Frames.bbo
       ; per_frame "funding" Frames.funding
       ; l2_replay ()
       ])
;;
