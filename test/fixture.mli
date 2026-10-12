(** Recorded OKX mainnet frames under [fixtures/], in market-recorder's raw minute layout
    ([raw/okx/<stream>/BTC-USDT-SWAP/2026/10/12/16-53.ndjson], one [<recv_ts> <frame>]
    line per websocket text frame). Each is the start of the first minute after
    connecting, trimmed to stay small: after the subscription acks, 149 [trades] pushes,
    249 [bbo-tbt] pushes, the 400-level [books] snapshot and 58 deltas, and 119
    [funding-rate], [mark-price] and [index-tickers] pushes. *)

open! Core

(** The directory holding [raw/], relative to the test directory. *)
val data_dir : string

val date : Date.t
val streams : Market_data.Stream.t list

(** The lines of one stream's minute file, in arrival order. *)
val lines : Market_data.Stream.t -> Market_data.Raw_minute.Line.t list

(** Just the frames of {!lines}. *)
val frames : Market_data.Stream.t -> string list
