(** A live {!Market_data.Feed.t} over the OKX v5 public websocket. Read-only, no
    credentials.

    Each requested stream gets its own {!Venue_net.Ws_client} connection, so [on_raw]
    knows which stream a frame belongs to:

    - [Trades]: [trades]
    - [Bbo]: [bbo-tbt]
    - [L2]: [books] (400 levels, snapshot then 100 ms deltas, sequenced by
      [seqId]/[prevSeqId])
    - [Funding]: [funding-rate] and [mark-price] of the symbol plus [index-tickers] of its
      index, merged by {!Normalizer}

    The connection sends the text frame [ping] every 20 s (OKX drops connections silent
    for 30 s) and is replaced after two silent intervals. On every (re)connect all the
    stream's channels are subscribed again in one request; L2 books are reset, so each
    reconnect yields a fresh [Snapshot]. A book sequence gap unsubscribes and resubscribes
    that channel. Frames that do not decode, and OKX error events, are logged and skipped.

    [recv_ts] is [Time_ns.now ()] when the frame is received; [on_raw] gets that frame
    unparsed, first, including acks and pongs. Pipes of streams that were not requested
    stay empty until [close]. Writes do not wait for readers. *)

open! Core
open Async

(** Raises if a first connection fails, or if [streams] contains [Private]. *)
val create
  :  ?on_raw:(stream:Market_data.Stream.t -> recv_ts:Time_ns.t -> string -> unit)
  -> Config.t
  -> symbols:string list
  -> streams:Market_data.Stream.t list
  -> Market_data.Feed.t Deferred.t

(** The subscriptions of a stream, e.g. [Funding] for [BTC-USDT-SWAP] is [funding-rate]
    and [mark-price] on [BTC-USDT-SWAP] and [index-tickers] on [BTC-USDT]. *)
val args : Market_data.Stream.t -> symbols:string list -> Wire.Arg.t list
