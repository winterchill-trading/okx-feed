(* [Market_data.Rebuild_norm] over the recorded minutes with [Md_normalizer], read back
   from the event logs it writes. *)

open! Core
open Async
open Okx_feed

let with_temp_dir f =
  let%bind dir = Unix.mkdtemp (Filename.temp_dir_name ^/ "okx-feed-test") in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      Process.run_expect_no_stdout_exn ~prog:"rm" ~args:[ "-rf"; dir ] ())
;;

let%expect_test "rebuild-norm over the recorded minute" =
  Log.Global.set_output [];
  with_temp_dir (fun dir ->
    let out_dir = dir ^/ "norm" in
    let%bind stats =
      Market_data.Rebuild_norm.run
        ~normalizers:[ Md_normalizer.normalizer ]
        ~data_dir:Fixture.data_dir
        ~out_dir
        Fixture.date
    in
    print_s [%sexp (stats : Market_data.Rebuild_norm.Stats.t Or_error.t)];
    let instrument = Normalizer.instrument "BTC-USDT-SWAP" in
    let%map () =
      Deferred.List.iter Fixture.streams ~how:`Sequential ~f:(fun stream ->
        let path =
          Market_data.Event_log.path ~dir:out_dir instrument stream Fixture.date
        in
        let%map events, (_ : Market_data.Framed.Tail.t) =
          Market_data.Event_log.load_file path
        in
        let first_recv_ts =
          Option.map (List.hd events) ~f:(fun (e : Market_data.Event.t) ->
            Time_ns.to_string_utc (Market_data.Event.recv_ts e))
        in
        print_s
          [%message
            ""
              ~file:(String.chop_prefix_exn path ~prefix:(dir ^ "/") : string)
              ~events:(List.length events : int)
              (first_recv_ts : string option)])
    in
    [%expect
      {|
      (Ok
       ((files 4) (frames 582) (disconnects 0) (events 539) (frame_errors 0)
        (first_errors ()) (skipped_files 0) (skipped_venues ())))
      ((file norm/okx/BTC-USDT-SWAP/norm/trades/2026-10-12.bin) (events 149)
       (first_recv_ts ("2026-10-12 16:53:44.494869000Z")))
      ((file norm/okx/BTC-USDT-SWAP/norm/bbo/2026-10-12.bin) (events 249)
       (first_recv_ts ("2026-10-12 16:53:45.654693000Z")))
      ((file norm/okx/BTC-USDT-SWAP/norm/l2/2026-10-12.bin) (events 59)
       (first_recv_ts ("2026-10-12 16:53:46.863769000Z")))
      ((file norm/okx/BTC-USDT-SWAP/norm/funding/2026-10-12.bin) (events 82)
       (first_recv_ts ("2026-10-12 16:53:47.416805000Z")))
      |}])
;;
