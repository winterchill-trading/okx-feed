(* [Live_feed] takes frames from [Ws_client] through [on_message]; before, it read
   [Ws_client.messages] one frame at a time ([Live_feed.For_testing.start_via_messages]).
   Both deliveries are run over the recorded mainnet minute of every stream, written in
   one burst by the fake server: they must produce the same events, gaps and stats, and
   the new one saves the pipe hop's words per frame. *)

open! Core
open Async
open Okx_feed

let symbols = [ "BTC-USDT-SWAP" ]

type run =
  { live : Live_feed.t
  ; server : Fake_ws.t
  ; seen : int ref
  ; until : (int * unit Ivar.t) option ref
  }

let start start stream =
  let%bind server = Fake_ws.start () in
  (* A clock that never moves: [recv_ts] is the same on both runs and no keepalive fires. *)
  let time_source = Time_source.read_only (Time_source.create ~now:Time_ns.epoch ()) in
  let seen = ref 0 in
  let until = ref None in
  (* Counts frames and wakes [deliver], without polling (a polling loop would add its own
     words to the measurement). *)
  let on_raw ~stream:_ ~recv_ts:_ _ =
    incr seen;
    match !until with
    | Some (target, ivar) when !seen >= target -> Ivar.fill_if_empty ivar ()
    | _ -> ()
  in
  let%bind live =
    start ~on_raw ~time_source (Fake_ws.config server) ~symbols ~streams:[ stream ]
  in
  let%map (_ : bool) =
    Fake_ws.wait_until (fun () -> not (List.is_empty (Fake_ws.received server)))
  in
  { live; server; seen; until }
;;

let burst frames = String.concat (List.map frames ~f:Fake_ws.encode_text_frame)

(* Writes [frames] in one burst and waits until the feed has seen them all. *)
let deliver { server; seen; until; _ } frames =
  let ivar = Ivar.create () in
  until := Some (!seen + List.length frames, ivar);
  Fake_ws.write_raw server (burst frames);
  Ivar.read ivar
;;

let drain pipe sexp_of =
  match Pipe.read_now' pipe with
  | `Ok q -> List.map (Queue.to_list q) ~f:sexp_of
  | `Eof | `Nothing_available -> []
;;

let outputs { live; _ } =
  let module F = (val Live_feed.feed_with_gaps live : Market_data.Feed.With_gaps.S) in
  [%sexp
    { trades = (drain F.trades Market_data.Trade.sexp_of_t : Sexp.t list)
    ; bbo = (drain F.bbo Market_data.Bbo.sexp_of_t : Sexp.t list)
    ; l2 = (drain F.l2 Market_data.L2_update.sexp_of_t : Sexp.t list)
    ; funding = (drain F.funding Market_data.Funding.sexp_of_t : Sexp.t list)
    ; gaps = (drain F.gaps Market_data.Gap.sexp_of_t : Sexp.t list)
    ; stats = (Live_feed.stats live : Live_feed.Stats.t)
    }]
;;

(* Events per pipe (trades, bbo, l2, funding, gaps). Counts rather than the sexp: its
   timestamps print in the machine's time zone. *)
let events : Sexp.t -> int list = function
  | List fields ->
    List.filter_map fields ~f:(function
      | List [ Atom "stats"; _ ] -> None
      | List [ Atom _; List items ] -> Some (List.length items)
      | _ -> None)
  | Atom _ -> []
;;

let stop { live; server; _ } =
  let module F = (val Live_feed.feed live : Market_data.Feed.S) in
  let%bind () = F.close () in
  Fake_ws.close server
;;

let via_messages ~on_raw ~time_source config ~symbols ~streams =
  Live_feed.For_testing.start_via_messages ~on_raw ~time_source config ~symbols ~streams
;;

let on_message ~on_raw ~time_source config ~symbols ~streams =
  Live_feed.start ~on_raw ~time_source config ~symbols ~streams
;;

let%expect_test "on_message and the messages pipe give the same output on every stream" =
  Log.Global.set_output [];
  let%map () =
    Deferred.List.iter ~how:`Sequential Fixture.streams ~f:(fun stream ->
      let frames = Fixture.frames stream in
      let%bind old = start via_messages stream in
      let%bind new_ = start on_message stream in
      let%bind () = deliver old frames in
      let%bind () = deliver new_ frames in
      let old_out = outputs old in
      let new_out = outputs new_ in
      print_s
        [%message
          ""
            (stream : Market_data.Stream.t)
            ~frames:(List.length frames : int)
            ~same:(Sexp.equal old_out new_out : bool)
            ~events:(events old_out : int list)];
      let%bind () = stop old in
      stop new_)
  in
  [%expect
    {|
    ((stream Trades) (frames 150) (same true) (events (149 0 0 0 0)))
    ((stream Bbo) (frames 250) (same true) (events (0 249 0 0 0)))
    ((stream L2) (frames 60) (same true) (events (0 0 59 0 0)))
    ((stream Funding) (frames 122) (same true) (events (0 0 0 82 0)))
    |}]
;;

(* Minor words per frame over the whole receive phase: socket reads, websocket framing,
   the delivery, [Normalizer.frame] and the pipe writes. The fake server's raw write of
   the burst is included and costs a few words in total. *)
let words_per_frame start_fn =
  let frames = List.concat (List.init 10 ~f:(fun _ -> Fixture.frames Trades)) in
  let%bind run = start start_fn Market_data.Stream.Trades in
  (* A warm-up burst, so buffers are grown before measuring. *)
  let%bind () = deliver run frames in
  ignore (outputs run : Sexp.t);
  let before = Gc.minor_words () in
  let%bind () = deliver run frames in
  let words = Gc.minor_words () - before in
  ignore (outputs run : Sexp.t);
  let%map () = stop run in
  Float.of_int words /. Float.of_int (List.length frames)
;;

(* Prints [~expected] when [actual] is within [tolerance] of it, the value otherwise. *)
let approx ~expected ~tolerance actual =
  if Float.( <= ) (Float.abs (actual -. expected)) tolerance
  then sprintf "~%g" expected
  else sprintf "%.1f (pinned %g +/- %g)" actual expected tolerance
;;

let%expect_test "words per trades frame, end to end" =
  Log.Global.set_output [];
  let%bind old = words_per_frame via_messages in
  let%bind new_ = words_per_frame on_message in
  (* arm64 macOS, dev profile: 138.7 and 125.6 to 125.8 (socket reads batch frames
     differently from run to run). The totals carry the socket and framing work, so they
     get a few words of slack for Linux CI; the saving is the pipe hop, about 13 words per
     frame on every platform (venue-net's README). *)
  print_s
    [%message
      ""
        ~via_messages:(approx ~expected:139. ~tolerance:4. old : string)
        ~on_message:(approx ~expected:126. ~tolerance:4. new_ : string)
        ~saved:(approx ~expected:13. ~tolerance:1. (old -. new_) : string)];
  [%expect {| ((via_messages ~139) (on_message ~126) (saved ~13)) |}];
  return ()
;;
