(* The recorded mainnet minute of every stream, decoded and normalized the way [Live_feed]
   does it. *)

open! Core
open Okx_feed

type counts =
  { frames : int
  ; empty : int (** acks and heartbeats: no events *)
  ; errors : int
  ; trades : int
  ; bbos : int
  ; fundings : int
  ; snapshots : int
  ; deltas : int
  ; resubscribes : int
  }
[@@deriving sexp_of]

let zero =
  { frames = 0
  ; empty = 0
  ; errors = 0
  ; trades = 0
  ; bbos = 0
  ; fundings = 0
  ; snapshots = 0
  ; deltas = 0
  ; resubscribes = 0
  }
;;

let count_event c (event : Market_data.Event.t) =
  match event with
  | Trade _ -> { c with trades = c.trades + 1 }
  | Bbo _ -> { c with bbos = c.bbos + 1 }
  | Funding _ -> { c with fundings = c.fundings + 1 }
  | L2 { kind = Snapshot; _ } -> { c with snapshots = c.snapshots + 1 }
  | L2 { kind = Delta; _ } -> { c with deltas = c.deltas + 1 }
;;

let replay stream =
  let t = Normalizer.create () in
  List.fold (Fixture.lines stream) ~init:zero ~f:(fun c line ->
    match line with
    | Disconnect ->
      Normalizer.reset t;
      c
    | Frame { recv_ts; payload } ->
      let c = { c with frames = c.frames + 1 } in
      (match Normalizer.frame t ~recv_ts payload with
       | Error _ -> { c with errors = c.errors + 1 }
       | Ok { events = []; resubscribe = [] } -> { c with empty = c.empty + 1 }
       | Ok { events; resubscribe } ->
         let c = List.fold events ~init:c ~f:count_event in
         { c with resubscribes = c.resubscribes + List.length resubscribe }))
;;

let%expect_test "every recorded frame decodes" =
  List.iter Fixture.streams ~f:(fun stream ->
    print_s [%message "" (stream : Market_data.Stream.t) ~_:(replay stream : counts)]);
  [%expect
    {|
    ((stream Trades)
     ((frames 150) (empty 1) (errors 0) (trades 149) (bbos 0) (fundings 0)
      (snapshots 0) (deltas 0) (resubscribes 0)))
    ((stream Bbo)
     ((frames 250) (empty 1) (errors 0) (trades 0) (bbos 249) (fundings 0)
      (snapshots 0) (deltas 0) (resubscribes 0)))
    ((stream L2)
     ((frames 60) (empty 1) (errors 0) (trades 0) (bbos 0) (fundings 0)
      (snapshots 1) (deltas 58) (resubscribes 0)))
    ((stream Funding)
     ((frames 122) (empty 40) (errors 0) (trades 0) (bbos 0) (fundings 82)
      (snapshots 0) (deltas 0) (resubscribes 0)))
    |}]
;;
