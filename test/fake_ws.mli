(** A scripted websocket server on a free local port: it accepts every upgrade, records
    the text frames clients send and lets a test push frames or drop connections. *)

open! Core
open Async

type t

val start : unit -> t Deferred.t

(** A config whose websocket endpoint is the server. *)
val config : t -> Okx_feed.Config.t

(** Upgrades accepted so far. *)
val connections : t -> int

(** Text frames received from clients, oldest first. *)
val received : t -> string list

(** Sends a text frame on the newest connection. *)
val send : t -> string -> unit

(** [payload] as one websocket text frame from the server, header included. *)
val encode_text_frame : string -> string

(** Writes already encoded frames (see {!encode_text_frame}) straight to the newest
    connection's socket, so a burst costs the server almost nothing per frame. *)
val write_raw : t -> string -> unit

(** Closes the newest connection. *)
val drop : t -> unit Deferred.t

(** Polls [f] in real time (loopback I/O takes milliseconds) until it holds or [timeout]
    (default 5s) passes. *)
val wait_until : ?timeout:Time_ns.Span.t -> (unit -> bool) -> bool Deferred.t

val close : t -> unit Deferred.t
