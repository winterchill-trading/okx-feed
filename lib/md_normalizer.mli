(** {!Normalizer} as a {!Market_data.Normalizer.S}, so that [Market_data.Rebuild_norm] can
    rebuild [norm/] event logs from recorded OKX raw minutes. [frame] keeps the events and
    drops the resubscription requests (a recording cannot resubscribe; the book waits for
    the next snapshot); [disconnect] is {!Normalizer.reset}. *)

open! Core
include Market_data.Normalizer.S with type t = Normalizer.t

(** This module as a first-class value, for [Rebuild_norm.run ~normalizers]. *)
val normalizer : Market_data.Normalizer.t
