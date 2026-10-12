(** JSON shapes of the OKX v5 public websocket messages this feed reads and sends.

    Numbers are kept as the strings OKX sends; {!Normalizer} parses them. Unknown fields
    are ignored. *)

open! Core

(** A channel subscription, e.g. [{"channel": "trades", "instId": "BTC-USDT-SWAP"}]. *)
module Arg : sig
  type t =
    { channel : string
    ; inst_id : string
    }
  [@@deriving sexp, compare, equal, hash, yojson]

  include Comparable.S with type t := t
  include Hashable.S with type t := t
end

(** [{"op": "subscribe" | "unsubscribe", "args": [...]}]. *)
module Request : sig
  type op =
    | Subscribe
    | Unsubscribe
  [@@deriving sexp_of]

  val to_string : op -> Arg.t list -> string
end

(** Acks, errors and notices: any message with an ["event"] field. *)
module Event : sig
  type t =
    { event : string (** [subscribe], [unsubscribe], [error], [notice] *)
    ; arg : Arg.t option
    ; code : string option
    ; msg : string option
    ; conn_id : string option
    }
  [@@deriving sexp_of, yojson]
end

module Action : sig
  type t =
    | Snapshot
    | Update
  [@@deriving sexp_of, equal]
end

(** [trades] *)
module Trade : sig
  type t =
    { inst_id : string
    ; trade_id : string
    ; px : string
    ; sz : string
    ; side : string (** taker side, [buy] or [sell] *)
    ; ts : string
    ; count : string option
    }
  [@@deriving sexp_of, yojson]
end

(** [books], [books5], [bbo-tbt] (and the VIP [*-l2-tbt] books). Levels are
    [[price, size, "0", order count]]. *)
module Book : sig
  type t =
    { asks : string list list
    ; bids : string list list
    ; ts : string
    ; seq_id : int option
    ; prev_seq_id : int option (** [-1] in a snapshot; absent on [bbo-tbt], [books5] *)
    ; checksum : int option (** deprecated, always [0] *)
    }
  [@@deriving sexp_of, yojson]
end

(** [funding-rate] *)
module Funding_rate : sig
  type t =
    { inst_id : string
    ; funding_rate : string
    ; funding_time : string (** settlement of the current period *)
    ; next_funding_time : string option
    ; ts : string
    }
  [@@deriving sexp_of, yojson]
end

(** [mark-price] *)
module Mark_price : sig
  type t =
    { inst_id : string
    ; mark_px : string
    ; ts : string
    }
  [@@deriving sexp_of, yojson]
end

(** [index-tickers] *)
module Index_ticker : sig
  type t =
    { inst_id : string
    ; idx_px : string
    ; ts : string
    }
  [@@deriving sexp_of, yojson]
end

(** [{"arg": ..., "action": ..., "data": [...]}] *)
module Push : sig
  type 'a t =
    { arg : Arg.t
    ; action : Action.t option
    ; data : 'a list
    }
  [@@deriving sexp_of]
end

module Message : sig
  type t =
    | Pong (** the text frame [pong] *)
    | Event of Event.t
    | Trades of Trade.t Push.t
    | Book of Book.t Push.t
    | Funding_rate of Funding_rate.t Push.t
    | Mark_price of Mark_price.t Push.t
    | Index_ticker of Index_ticker.t Push.t
    | Other of Arg.t (** a push on a channel this library does not decode *)
  [@@deriving sexp_of]

  (** Decodes one text frame. [Error] when it is not JSON or does not match the channel's
      shape. *)
  val of_string : string -> t Or_error.t
end

(** Channel names. *)

val trades : string
val bbo_tbt : string
val books : string
val funding_rate : string
val mark_price : string
val index_tickers : string
