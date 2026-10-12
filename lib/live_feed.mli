(** A live {!Market_data.Feed.t} over the OKX v5 public websocket. Read-only, no
    credentials.

    Each requested stream gets its own {!Venue_net.Ws_client} connection, so [on_raw]
    knows which stream a frame belongs to:

    - [Trades]: [trades]
    - [Bbo]: [bbo-tbt]
    - [L2]: [books] (400 levels, snapshot then 100 ms deltas, sequenced by
      [seqId]/[prevSeqId])
    - [Funding]: [funding-rate] and [mark-price] of the symbol plus [index-tickers] of its
      index, merged by {!Normalizer}; only for perpetual swaps (symbols ending in
      [-SWAP]). A stream with no channel for the given symbols opens no connection and its
      pipe stays empty.

    The connection sends the text frame [ping] every 20 s (OKX drops connections silent
    for 30 s) and is replaced after two silent intervals. On every (re)connect all the
    stream's channels are subscribed again in one request; L2 books are reset, so each
    reconnect yields a fresh [Snapshot]. A book sequence gap unsubscribes and resubscribes
    that channel. Frames that do not decode, and OKX error events, are logged and skipped.

    [recv_ts] is the time when the frame is received; [on_raw] gets that frame unparsed,
    first, including acks and pongs. [time_source] (default the wall clock) stamps
    [recv_ts] and drives the keepalive, the silence watchdog and the reconnection delay,
    so tests can step them. Pipes of streams that were not requested stay empty until
    [close]. Writes do not wait for readers. *)

open! Core
open Async

(** Raises if a first connection fails, or if [streams] contains [Private]. *)
val create
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> ?time_source:Time_source.t
  -> Config.t
  -> symbols:string list
  -> streams:Market_data.Stream.t list
  -> Market_data.Feed.t Deferred.t

(** A running feed with its counters. *)
type t

(** Like {!create}, keeping the handle for {!stats}. *)
val start
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> ?time_source:Time_source.t
  -> Config.t
  -> symbols:string list
  -> streams:Market_data.Stream.t list
  -> t Deferred.t

val feed : t -> Market_data.Feed.t

module Stats : sig
  type t =
    { frames : int (** websocket text frames received, acks and pongs included *)
    ; parse_errors : int
    (** frames that did not decode, or were OKX error events, and were skipped *)
    ; reconnects : int (** successful reconnections, summed over the connections *)
    }
  [@@deriving sexp_of]
end

val stats : t -> Stats.t

(** The subscriptions of a stream, e.g. [Funding] for [BTC-USDT-SWAP] is [funding-rate]
    and [mark-price] on [BTC-USDT-SWAP] and [index-tickers] on [BTC-USDT]; [Funding]
    ignores symbols that are not perpetual swaps. *)
val args : Market_data.Stream.t -> symbols:string list -> Wire.Arg.t list
