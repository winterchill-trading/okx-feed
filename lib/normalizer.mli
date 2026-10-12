(** Converts OKX public websocket frames into {!Market_data} records. Pure apart from
    logging; the Async driver is {!Live_feed}.

    - [trades]: one {!Market_data.Trade.t} per push entry ([exch_ts] = fill time [ts],
      side = taker side, [trade_id] = the last trade id of the aggregate).
    - [bbo-tbt]: a {!Market_data.Bbo.t} per push with both sides present ([exch_ts] =
      matching engine time [ts]).
    - [books] (and the other incremental books carrying [prevSeqId]): a snapshot becomes
      an [L2] [Snapshot] with levels sorted best first and starts the book's sequence;
      each update whose [prevSeqId] equals the last [seqId] becomes a [Delta]. Updates
      before the first snapshot are dropped. A sequence gap drops the book and asks for a
      resubscription (the server answers with a fresh snapshot). Heartbeat updates (no
      levels, [seqId = prevSeqId]) advance nothing and emit nothing. [books5] pushes,
      which carry no sequence, are each an [L2] [Snapshot].
    - [funding-rate], [mark-price] and [index-tickers] are merged per swap (the index of
      [BASE-QUOTE-SWAP] is [BASE-QUOTE], see {!index_of}): once all three are known, a
      {!Market_data.Funding.t} is emitted whenever the rate, the funding time, the mark or
      the index changes ([exch_ts] = [ts] of the message that changed it,
      [next_funding_time] = [fundingTime], the end of the current period).

    The [checksum] field is deprecated by OKX (always [0]) and ignored. *)

open! Core

module Output : sig
  type t =
    { events : Market_data.Event.t list
    ; resubscribe : Wire.Arg.t list (** subscriptions whose book hit a sequence gap *)
    }
  [@@deriving sexp_of]

  val empty : t
end

type t

val create : unit -> t

(** Drops every book, e.g. after a reconnect. Funding state is kept. *)
val reset : t -> unit

val instrument : string -> Market_data.Instrument.t

(** The index instrument of a contract: the first two dash-separated parts,
    ["BTC-USDT-SWAP"] -> ["BTC-USDT"]. *)
val index_of : string -> string

(** [Error] for an [error] event and for values that do not parse. Acks, notices and pongs
    give {!Output.empty}. *)
val message : t -> recv_ts:Time_ns.t -> Wire.Message.t -> Output.t Or_error.t

(** {!Wire.Message.of_string} then {!message}. *)
val frame : t -> recv_ts:Time_ns.t -> string -> Output.t Or_error.t
