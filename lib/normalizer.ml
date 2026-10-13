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
  ; swaps_by_index : (string * Swap.t) list String.Table.t
  (** the swaps of each index, sorted by symbol *)
  ; indexes : Md.Price.t String.Table.t
  ; trade_scan : Scan.trade
  ; book_scan : Scan.book
  ; mutable last_instrument : Md.Instrument.t
  (** the instrument of the last scanned frame, reused while the symbol repeats *)
  ; mutable last_arg : Wire.Arg.t (** likewise for the book key *)
  }

let instrument symbol = Md.Instrument.create Okx symbol

let create () =
  { books = Wire.Arg.Table.create ()
  ; swaps = String.Table.create ()
  ; swaps_by_index = String.Table.create ()
  ; indexes = String.Table.create ()
  ; trade_scan = Scan.create_trade ()
  ; book_scan = Scan.create_book ()
  ; last_instrument = instrument ""
  ; last_arg = { channel = ""; inst_id = "" }
  }
;;

let reset t = Hashtbl.clear t.books

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

(* Snapshot levels best first: bids descending, asks ascending. *)
let sort_bids =
  List.sort ~compare:(fun (a : Md.L2_update.Level.t) b ->
    Md.Price.compare b.price a.price)
;;

let sort_asks =
  List.sort ~compare:(fun (a : Md.L2_update.Level.t) b ->
    Md.Price.compare a.price b.price)
;;

let l2 ~recv_ts (kind : Md.L2_update.Kind.t) (arg : Wire.Arg.t) (book : Wire.Book.t) =
  let bids = List.map book.bids ~f:level
  and asks = List.map book.asks ~f:level in
  let bids, asks =
    match kind with
    | Delta -> bids, asks
    | Snapshot -> sort_bids bids, sort_asks asks
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

(* Sequencing shared by the Yojson and the scanned path: [l2 kind] builds the event,
   [no_levels] says whether the update carries any level. *)
let sequenced
  t
  ~(arg : Wire.Arg.t)
  ~(action : Wire.Action.t option)
  ~seq_id
  ~prev_seq_id
  ~no_levels
  ~(l2 : Md.L2_update.Kind.t -> Md.Event.t)
  =
  match action, seq_id with
  | (None | Some Snapshot), seq_id ->
    Option.iter seq_id ~f:(fun seq -> Hashtbl.set t.books ~key:arg ~data:seq);
    Output.events [ l2 Snapshot ]
  | Some Update, None -> raise_s [%message "book update without seqId"]
  | Some Update, Some seq_id ->
    (match Hashtbl.find t.books arg with
     | None -> Output.empty
     | Some last ->
       (match prev_seq_id with
        | Some prev when prev = last ->
          Hashtbl.set t.books ~key:arg ~data:seq_id;
          if no_levels then Output.empty else Output.events [ l2 Delta ]
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

let sequenced_book t ~recv_ts (push : Wire.Book.t Wire.Push.t) (book : Wire.Book.t) =
  sequenced
    t
    ~arg:push.arg
    ~action:push.action
    ~seq_id:book.seq_id
    ~prev_seq_id:book.prev_seq_id
    ~no_levels:(List.is_empty book.bids && List.is_empty book.asks)
    ~l2:(fun kind -> l2 ~recv_ts kind push.arg book)
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
  match Hashtbl.find t.swaps symbol with
  | Some swap -> swap
  | None ->
    let swap = { Swap.rate = None; mark = None; last = None } in
    Hashtbl.set t.swaps ~key:symbol ~data:swap;
    Hashtbl.update t.swaps_by_index (index_of symbol) ~f:(fun swaps ->
      List.merge
        (Option.value swaps ~default:[])
        [ symbol, swap ]
        ~compare:(fun (a, _) (b, _) -> String.compare a b));
    swap
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
    match Hashtbl.find t.swaps_by_index i.inst_id with
    | None -> []
    | Some swaps ->
      List.concat_map swaps ~f:(fun (symbol, swap) ->
        funding_of_swap t ~recv_ts ~exch_ts:(time i.ts) symbol swap))
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

let frame_reference t ~recv_ts frame =
  let%bind.Or_error decoded = Wire.Message.of_string frame in
  message t ~recv_ts decoded
;;

(* The scanned path: the same events as [frame_reference], built from {!Scan}'s reused
   records. *)

let time_of_ms ms = Time_ns.of_int_ns_since_epoch (ms * 1_000_000)

let scanned_instrument t s ~pos ~len =
  if Scan.substring_equal s ~pos ~len (Md.Symbol.to_string t.last_instrument.symbol)
  then t.last_instrument
  else (
    let instrument = instrument (String.sub s ~pos ~len) in
    t.last_instrument <- instrument;
    instrument)
;;

let scanned_arg t s (b : Scan.book) =
  let last = t.last_arg in
  if Scan.substring_equal s ~pos:b.channel_pos ~len:b.channel_len last.channel
     && Scan.substring_equal s ~pos:b.inst_pos ~len:b.inst_len last.inst_id
  then last
  else (
    let arg =
      { Wire.Arg.channel = String.sub s ~pos:b.channel_pos ~len:b.channel_len
      ; inst_id = String.sub s ~pos:b.inst_pos ~len:b.inst_len
      }
    in
    t.last_arg <- arg;
    arg)
;;

let scanned_trade t ~recv_ts s =
  let sc = t.trade_scan in
  Md.Event.Trade
    { instrument = scanned_instrument t s ~pos:sc.inst_pos ~len:sc.inst_len
    ; exch_ts = time_of_ms sc.ts
    ; recv_ts
    ; price = Md.Price.of_units sc.px
    ; size = Md.Size.of_units sc.sz
    ; side = (if sc.buy then Buy else Sell)
    ; trade_id = String.sub s ~pos:sc.trade_id_pos ~len:sc.trade_id_len
    }
;;

let scanned_bbo t ~recv_ts s =
  let sc = t.book_scan in
  if sc.asks.n = 0 || sc.bids.n = 0
  then Output.empty
  else
    Output.events
      [ Md.Event.Bbo
          { instrument = scanned_instrument t s ~pos:sc.inst_pos ~len:sc.inst_len
          ; exch_ts = time_of_ms sc.ts
          ; recv_ts
          ; bid_price = Md.Price.of_units sc.bids.px.(0)
          ; bid_size = Md.Size.of_units sc.bids.sz.(0)
          ; ask_price = Md.Price.of_units sc.asks.px.(0)
          ; ask_size = Md.Size.of_units sc.asks.sz.(0)
          }
      ]
;;

let scanned_levels (l : Scan.Levels.t) =
  let mutable acc = [] in
  for i = l.n - 1 downto 0 do
    acc
    <- { Md.L2_update.Level.price = Md.Price.of_units l.px.(i)
       ; size = Md.Size.of_units l.sz.(i)
       }
       :: acc
  done;
  acc
;;

(* Whether [px] is in order ([descending] for bids), so the snapshot sort can be skipped.
   OKX sends snapshots sorted. *)
let sorted (l : Scan.Levels.t) ~descending =
  let mutable ok = true in
  let mutable i = 1 in
  while ok && i < l.n do
    let a = l.px.(i - 1)
    and b = l.px.(i) in
    ok <- (if descending then a >= b else a <= b);
    i <- i + 1
  done;
  ok
;;

let scanned_l2 t ~recv_ts s (kind : Md.L2_update.Kind.t) =
  let sc = t.book_scan in
  let bids = scanned_levels sc.bids
  and asks = scanned_levels sc.asks in
  let bids, asks =
    match kind with
    | Delta -> bids, asks
    | Snapshot ->
      ( (if sorted sc.bids ~descending:true then bids else sort_bids bids)
      , if sorted sc.asks ~descending:false then asks else sort_asks asks )
  in
  Md.Event.L2
    { instrument = scanned_instrument t s ~pos:sc.inst_pos ~len:sc.inst_len
    ; exch_ts = time_of_ms sc.ts
    ; recv_ts
    ; kind
    ; bids
    ; asks
    }
;;

let scanned_book t ~recv_ts s =
  let sc = t.book_scan in
  sequenced
    t
    ~arg:(scanned_arg t s sc)
    ~action:(if sc.snapshot then Some Snapshot else Some Update)
    ~seq_id:(Some sc.seq_id)
    ~prev_seq_id:(Some sc.prev_seq_id)
    ~no_levels:(sc.asks.n = 0 && sc.bids.n = 0)
    ~l2:(fun kind -> scanned_l2 t ~recv_ts s kind)
;;

(* The level arrays start small and grow on the first book that does not fit. *)
let scan_book scan frame book =
  scan frame book
  || (Scan.full book
      &&
      (Scan.grow book;
       scan frame book))
;;

let frame t ~recv_ts frame =
  if Scan.trade frame t.trade_scan
  then Ok (Output.events [ scanned_trade t ~recv_ts frame ])
  else if scan_book Scan.bbo frame t.book_scan
  then Ok (scanned_bbo t ~recv_ts frame)
  else if scan_book Scan.book frame t.book_scan
  then Ok (scanned_book t ~recv_ts frame)
  else frame_reference t ~recv_ts frame
;;
