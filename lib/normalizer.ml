open! Core
module Md = Market_data

module Output = struct
  type t =
    { events : Md.Event.t list
    ; resubscribe : Wire.Arg.t list
    }
  [@@deriving sexp_of]

  let empty = { events = []; resubscribe = [] }
  let events events = { events; resubscribe = [] }
end

module Funding_key = struct
  type t =
    { rate : string
    ; funding_time : Time_ns.t
    ; mark : Md.Price.t
    ; index : Md.Price.t
    }
  [@@deriving equal]
end

module Swap = struct
  type t =
    { mutable rate : (string * Time_ns.t) option (** rate, funding time *)
    ; mutable mark : Md.Price.t option
    ; mutable last : Funding_key.t option (** last emitted *)
    }
end

type t =
  { books : int Wire.Arg.Table.t (** last [seqId] of each synced book *)
  ; swaps : Swap.t String.Table.t
  ; indexes : Md.Price.t String.Table.t
  }

let create () =
  { books = Wire.Arg.Table.create ()
  ; swaps = String.Table.create ()
  ; indexes = String.Table.create ()
  }
;;

let reset t = Hashtbl.clear t.books
let instrument symbol = Md.Instrument.create Okx symbol

let index_of symbol =
  match String.split symbol ~on:'-' with
  | base :: quote :: _ -> base ^ "-" ^ quote
  | [ _ ] | [] -> symbol
;;

let time ms = Time_ns.of_int_ns_since_epoch (Int.of_string ms * 1_000_000)

let side = function
  | "buy" -> Md.Side.Buy
  | "sell" -> Sell
  | other -> raise_s [%message "unknown trade side" other]
;;

let level = function
  | price :: size :: _ ->
    { Md.L2_update.Level.price = Md.Price.of_string price; size = Md.Size.of_string size }
  | other -> raise_s [%message "malformed book level" (other : string list)]
;;

let trades ~recv_ts (push : Wire.Trade.t Wire.Push.t) =
  List.map push.data ~f:(fun (trade : Wire.Trade.t) ->
    Md.Event.Trade
      { instrument = instrument trade.inst_id
      ; exch_ts = time trade.ts
      ; recv_ts
      ; price = Md.Price.of_string trade.px
      ; size = Md.Size.of_string trade.sz
      ; side = side trade.side
      ; trade_id = trade.trade_id
      })
;;

let bbo ~recv_ts (arg : Wire.Arg.t) (book : Wire.Book.t) =
  match book.bids, book.asks with
  | bid :: _, ask :: _ ->
    let bid = level bid
    and ask = level ask in
    [ Md.Event.Bbo
        { instrument = instrument arg.inst_id
        ; exch_ts = time book.ts
        ; recv_ts
        ; bid_price = bid.price
        ; bid_size = bid.size
        ; ask_price = ask.price
        ; ask_size = ask.size
        }
    ]
  | _ -> []
;;

let l2 ~recv_ts (kind : Md.L2_update.Kind.t) (arg : Wire.Arg.t) (book : Wire.Book.t) =
  let bids = List.map book.bids ~f:level
  and asks = List.map book.asks ~f:level in
  let bids, asks =
    match kind with
    | Delta -> bids, asks
    | Snapshot ->
      ( List.sort bids ~compare:(fun (a : Md.L2_update.Level.t) b ->
          Md.Price.compare b.price a.price)
      , List.sort asks ~compare:(fun (a : Md.L2_update.Level.t) b ->
          Md.Price.compare a.price b.price) )
  in
  Md.Event.L2
    { instrument = instrument arg.inst_id
    ; exch_ts = time book.ts
    ; recv_ts
    ; kind
    ; bids
    ; asks
    }
;;

let sequenced_book t ~recv_ts (push : Wire.Book.t Wire.Push.t) (book : Wire.Book.t) =
  let arg = push.arg in
  match push.action, book.seq_id with
  | (None | Some Snapshot), seq_id ->
    Option.iter seq_id ~f:(fun seq -> Hashtbl.set t.books ~key:arg ~data:seq);
    Output.events [ l2 ~recv_ts Snapshot arg book ]
  | Some Update, None -> raise_s [%message "book update without seqId"]
  | Some Update, Some seq_id ->
    (match Hashtbl.find t.books arg with
     | None -> Output.empty
     | Some last ->
       (match book.prev_seq_id with
        | Some prev when prev = last ->
          Hashtbl.set t.books ~key:arg ~data:seq_id;
          if List.is_empty book.bids && List.is_empty book.asks
          then Output.empty
          else Output.events [ l2 ~recv_ts Delta arg book ]
        | prev ->
          Hashtbl.remove t.books arg;
          Async.Log.Global.info_s
            [%message
              "okx feed: book sequence gap, resubscribing"
                ~channel:arg.channel
                ~inst_id:arg.inst_id
                ~expected_prev_seq_id:(last : int)
                ~prev_seq_id:(prev : int option)
                (seq_id : int)];
          { events = []; resubscribe = [ arg ] }))
;;

let book t ~recv_ts (push : Wire.Book.t Wire.Push.t) =
  let outputs =
    List.map push.data ~f:(fun (book : Wire.Book.t) ->
      if String.equal push.arg.channel Wire.bbo_tbt
      then Output.events (bbo ~recv_ts push.arg book)
      else (
        match book.prev_seq_id, push.action with
        | None, None -> Output.events [ l2 ~recv_ts Snapshot push.arg book ]
        | _ -> sequenced_book t ~recv_ts push book))
  in
  { Output.events = List.concat_map outputs ~f:(fun o -> o.events)
  ; resubscribe = List.concat_map outputs ~f:(fun o -> o.resubscribe)
  }
;;

let swap t symbol =
  Hashtbl.find_or_add t.swaps symbol ~default:(fun () ->
    { Swap.rate = None; mark = None; last = None })
;;

let funding_of_swap t ~recv_ts ~exch_ts symbol (swap : Swap.t) =
  match swap.rate, swap.mark, Hashtbl.find t.indexes (index_of symbol) with
  | Some (rate, funding_time), Some mark, Some index ->
    let key = { Funding_key.rate; funding_time; mark; index } in
    if Option.equal Funding_key.equal swap.last (Some key)
    then []
    else (
      swap.last <- Some key;
      [ Md.Event.Funding
          { instrument = instrument symbol
          ; exch_ts
          ; recv_ts
          ; rate = Float.of_string rate
          ; next_funding_time = funding_time
          ; mark_price = mark
          ; index_price = index
          }
      ])
  | _ -> []
;;

let funding_rate t ~recv_ts (push : Wire.Funding_rate.t Wire.Push.t) =
  List.concat_map push.data ~f:(fun (f : Wire.Funding_rate.t) ->
    let swap = swap t f.inst_id in
    ignore (Float.of_string f.funding_rate : float);
    swap.rate <- Some (f.funding_rate, time f.funding_time);
    funding_of_swap t ~recv_ts ~exch_ts:(time f.ts) f.inst_id swap)
;;

let mark_price t ~recv_ts (push : Wire.Mark_price.t Wire.Push.t) =
  List.concat_map push.data ~f:(fun (m : Wire.Mark_price.t) ->
    let swap = swap t m.inst_id in
    swap.mark <- Some (Md.Price.of_string m.mark_px);
    funding_of_swap t ~recv_ts ~exch_ts:(time m.ts) m.inst_id swap)
;;

let index_ticker t ~recv_ts (push : Wire.Index_ticker.t Wire.Push.t) =
  List.concat_map push.data ~f:(fun (i : Wire.Index_ticker.t) ->
    Hashtbl.set t.indexes ~key:i.inst_id ~data:(Md.Price.of_string i.idx_px);
    Hashtbl.to_alist t.swaps
    |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
    |> List.concat_map ~f:(fun (symbol, swap) ->
      if String.equal (index_of symbol) i.inst_id
      then funding_of_swap t ~recv_ts ~exch_ts:(time i.ts) symbol swap
      else []))
;;

let message t ~recv_ts (message : Wire.Message.t) =
  Or_error.try_with_join (fun () ->
    match message with
    | Pong | Other _ -> Ok Output.empty
    | Event { event = "error"; code; msg; arg; _ } ->
      Or_error.error_s
        [%message
          "OKX error event"
            (code : string option)
            (msg : string option)
            (arg : Wire.Arg.t option)]
    | Event { event = "notice"; code; msg; _ } ->
      Async.Log.Global.info_s
        [%message "okx feed: notice" (code : string option) (msg : string option)];
      Ok Output.empty
    | Event _ -> Ok Output.empty
    | Trades push -> Ok (Output.events (trades ~recv_ts push))
    | Book push -> Ok (book t ~recv_ts push)
    | Funding_rate push -> Ok (Output.events (funding_rate t ~recv_ts push))
    | Mark_price push -> Ok (Output.events (mark_price t ~recv_ts push))
    | Index_ticker push -> Ok (Output.events (index_ticker t ~recv_ts push)))
;;

let frame t ~recv_ts frame =
  let%bind.Or_error decoded = Wire.Message.of_string frame in
  message t ~recv_ts decoded
;;
