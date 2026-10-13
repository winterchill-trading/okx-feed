(** Allocation-free readers for the OKX pushes that dominate a feed: [trades], [bbo-tbt]
    and the sequenced [books] channels. Each reads one frame into a reused record and
    returns [false] for any shape it does not recognise (a reordered [arg], several
    entries in [data], escapes, nested objects, numbers it cannot read exactly), so the
    caller can fall back to the Yojson decoder in {!Wire}. A [true] result reads the same
    values {!Wire.Message.of_string} would.

    Strings are positions into the frame ([*_pos], [*_len]); decimals are [int]s in units
    of 10^-8, as {!Market_data.Price.of_units} takes them. *)

open! Core

(** Number of levels per side a {!book} can hold; a side with more falls back. *)
val max_levels : int

module Levels : sig
  type t = private
    { mutable n : int
    ; mutable px : int array
    ; mutable sz : int array
    ; mutable full : bool (** the last read stopped at the capacity *)
    }

  val create : unit -> t
end

type trade =
  { mutable inst_pos : int
  ; mutable inst_len : int
  ; mutable trade_id_pos : int
  ; mutable trade_id_len : int
  ; mutable px : int
  ; mutable sz : int
  ; mutable buy : bool
  ; mutable ts : int (** milliseconds since the epoch *)
  }

type book =
  { mutable channel_pos : int
  ; mutable channel_len : int
  ; mutable inst_pos : int
  ; mutable inst_len : int
  ; mutable snapshot : bool (** [action] is [snapshot] (else [update]); unused on bbo *)
  ; mutable ts : int
  ; mutable seq_id : int
  ; mutable prev_seq_id : int
  ; asks : Levels.t
  ; bids : Levels.t
  ; mutable after : int (** scratch: where the next key search starts *)
  }

val create_trade : unit -> trade

(** Starts with room for a few levels per side, so a [bbo-tbt] reader stays small. *)
val create_book : unit -> book

(** Whether {!bbo} or {!book} returned [false] because a side did not fit. *)
val full : book -> bool

(** Gives both sides room for {!max_levels} levels (a read stops at the first side that
    does not fit, so the other one may not fit either). *)
val grow : book -> unit

(** Position just after [key] in [s.[from] .. s.[until - 1]], or [-1]. *)
val find_key : string -> from:int -> until:int -> string -> int
[@@zero_alloc]

(** The decimal string starting at [pos] and closed by a ['"'] (digits with an optional
    ['.'] and at least one fractional digit; at most 10 integer digits; fractional digits
    past the eighth are truncated, as {!Fixed_decimal} does), in units of 10^-8; [-1] for
    anything else. *)
val decimal : string -> int -> int
[@@zero_alloc]

(** A [trades] push with exactly one entry. *)
val trade : string -> trade -> bool
[@@zero_alloc]

(** A [bbo-tbt] push with exactly one entry. [seq_id], [prev_seq_id] and [snapshot] are
    not read. *)
val bbo : string -> book -> bool
[@@zero_alloc]

(** A push on a [books*] channel with an [action], one entry, and both [seqId] and
    [prevSeqId]. *)
val book : string -> book -> bool
[@@zero_alloc]

(** [s.[pos] .. s.[pos + len - 1]] equals [t]. *)
val substring_equal : string -> pos:int -> len:int -> string -> bool
[@@zero_alloc]
