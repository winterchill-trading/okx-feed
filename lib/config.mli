(** Where to connect. Only the public endpoint is used. *)

open! Core

type t = { url : Uri.t } [@@deriving sexp_of]

(** [wss://ws.okx.com:8443/ws/v5/public] *)
val mainnet_url : Uri.t

val mainnet : t

(** [create ()] is {!mainnet}; [url] overrides the endpoint (e.g. the demo trading
    endpoint [wss://wspap.okx.com:8443/ws/v5/public] or a local proxy). *)
val create : ?url:Uri.t -> unit -> t
