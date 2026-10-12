open! Core
open Ppx_yojson_conv_lib.Yojson_conv.Primitives

let trades = "trades"
let bbo_tbt = "bbo-tbt"
let books = "books"
let funding_rate = "funding-rate"
let mark_price = "mark-price"
let index_tickers = "index-tickers"

module Arg = struct
  module T = struct
    type t =
      { channel : string
      ; inst_id : string [@key "instId"]
      }
    [@@deriving sexp, compare, equal, hash, yojson] [@@yojson.allow_extra_fields]
  end

  include T
  include Comparable.Make (T)
  include Hashable.Make (T)
end

module Request = struct
  type op =
    | Subscribe
    | Unsubscribe
  [@@deriving sexp_of]

  let to_string op args =
    let op =
      match op with
      | Subscribe -> "subscribe"
      | Unsubscribe -> "unsubscribe"
    in
    Yojson.Safe.to_string
      (`Assoc [ "op", `String op; "args", `List (List.map args ~f:Arg.yojson_of_t) ])
  ;;
end

module Event = struct
  type t =
    { event : string
    ; arg : Arg.t option [@default None]
    ; code : string option [@default None]
    ; msg : string option [@default None]
    ; conn_id : string option [@key "connId"] [@default None]
    }
  [@@deriving sexp_of, yojson] [@@yojson.allow_extra_fields]
end

module Action = struct
  type t =
    | Snapshot
    | Update
  [@@deriving sexp_of, equal]

  let of_string = function
    | "snapshot" -> Snapshot
    | "update" -> Update
    | other -> raise_s [%message "unknown action" other]
  ;;
end

module Trade = struct
  type t =
    { inst_id : string [@key "instId"]
    ; trade_id : string [@key "tradeId"]
    ; px : string
    ; sz : string
    ; side : string
    ; ts : string
    ; count : string option [@default None]
    }
  [@@deriving sexp_of, yojson] [@@yojson.allow_extra_fields]
end

module Book = struct
  type t =
    { asks : string list list
    ; bids : string list list
    ; ts : string
    ; seq_id : int option [@key "seqId"] [@default None]
    ; prev_seq_id : int option [@key "prevSeqId"] [@default None]
    ; checksum : int option [@default None]
    }
  [@@deriving sexp_of, yojson] [@@yojson.allow_extra_fields]
end

module Funding_rate = struct
  type t =
    { inst_id : string [@key "instId"]
    ; funding_rate : string [@key "fundingRate"]
    ; funding_time : string [@key "fundingTime"]
    ; next_funding_time : string option [@key "nextFundingTime"] [@default None]
    ; ts : string
    }
  [@@deriving sexp_of, yojson] [@@yojson.allow_extra_fields]
end

module Mark_price = struct
  type t =
    { inst_id : string [@key "instId"]
    ; mark_px : string [@key "markPx"]
    ; ts : string
    }
  [@@deriving sexp_of, yojson] [@@yojson.allow_extra_fields]
end

module Index_ticker = struct
  type t =
    { inst_id : string [@key "instId"]
    ; idx_px : string [@key "idxPx"]
    ; ts : string
    }
  [@@deriving sexp_of, yojson] [@@yojson.allow_extra_fields]
end

module Push = struct
  type 'a t =
    { arg : Arg.t
    ; action : Action.t option
    ; data : 'a list
    }
  [@@deriving sexp_of]
end

module Message = struct
  type t =
    | Pong
    | Event of Event.t
    | Trades of Trade.t Push.t
    | Book of Book.t Push.t
    | Funding_rate of Funding_rate.t Push.t
    | Mark_price of Mark_price.t Push.t
    | Index_ticker of Index_ticker.t Push.t
    | Other of Arg.t
  [@@deriving sexp_of]

  let push fields arg ~data_of_yojson =
    let action =
      match List.Assoc.find fields "action" ~equal:String.equal with
      | Some (`String action) -> Some (Action.of_string action)
      | Some `Null | None -> None
      | Some other ->
        raise_s [%message "action is not a string" ~_:(Yojson.Safe.to_string other)]
    in
    let data =
      match List.Assoc.find fields "data" ~equal:String.equal with
      | Some (`List data) -> List.map data ~f:data_of_yojson
      | Some _ | None -> raise_s [%message "push without a data array"]
    in
    { Push.arg; action; data }
  ;;

  let of_json (json : Yojson.Safe.t) =
    match json with
    | `Assoc fields ->
      if List.Assoc.mem fields "event" ~equal:String.equal
      then Event (Event.t_of_yojson json)
      else (
        match List.Assoc.find fields "arg" ~equal:String.equal with
        | None -> raise_s [%message "neither an event nor a push"]
        | Some arg ->
          let arg = Arg.t_of_yojson arg in
          let channel = arg.channel in
          if String.equal channel trades
          then Trades (push fields arg ~data_of_yojson:Trade.t_of_yojson)
          else if String.equal channel funding_rate
          then Funding_rate (push fields arg ~data_of_yojson:Funding_rate.t_of_yojson)
          else if String.equal channel mark_price
          then Mark_price (push fields arg ~data_of_yojson:Mark_price.t_of_yojson)
          else if String.equal channel index_tickers
          then Index_ticker (push fields arg ~data_of_yojson:Index_ticker.t_of_yojson)
          else if String.equal channel bbo_tbt || String.is_prefix channel ~prefix:"books"
          then Book (push fields arg ~data_of_yojson:Book.t_of_yojson)
          else Other arg)
    | _ -> raise_s [%message "frame is not a JSON object"]
  ;;

  let of_string frame =
    match String.strip frame with
    | "pong" -> Ok Pong
    | frame ->
      Or_error.try_with (fun () -> of_json (Yojson.Safe.from_string frame))
      |> Or_error.tag ~tag:"cannot decode OKX frame"
  ;;
end
