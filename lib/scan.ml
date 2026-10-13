open! Core

let max_levels = 1024

module Levels = struct
  type t =
    { mutable n : int
    ; mutable px : int array
    ; mutable sz : int array
    ; mutable full : bool
    }

  (* Small enough to stay in the minor heap; books grow it once. *)
  let initial_capacity = 8

  let create () =
    { n = 0
    ; px = Array.create ~len:initial_capacity 0
    ; sz = Array.create ~len:initial_capacity 0
    ; full = false
    }
  ;;

  let grow t =
    if Array.length t.px < max_levels
    then (
      t.px <- Array.create ~len:max_levels 0;
      t.sz <- Array.create ~len:max_levels 0);
    t.full <- false
  ;;
end

type trade =
  { mutable inst_pos : int
  ; mutable inst_len : int
  ; mutable trade_id_pos : int
  ; mutable trade_id_len : int
  ; mutable px : int
  ; mutable sz : int
  ; mutable buy : bool
  ; mutable ts : int
  }

type book =
  { mutable channel_pos : int
  ; mutable channel_len : int
  ; mutable inst_pos : int
  ; mutable inst_len : int
  ; mutable snapshot : bool
  ; mutable ts : int
  ; mutable seq_id : int
  ; mutable prev_seq_id : int
  ; asks : Levels.t
  ; bids : Levels.t
  }

let create_trade () =
  { inst_pos = 0
  ; inst_len = 0
  ; trade_id_pos = 0
  ; trade_id_len = 0
  ; px = 0
  ; sz = 0
  ; buy = false
  ; ts = 0
  }
;;

let create_book () =
  { channel_pos = 0
  ; channel_len = 0
  ; inst_pos = 0
  ; inst_len = 0
  ; snapshot = false
  ; ts = 0
  ; seq_id = 0
  ; prev_seq_id = 0
  ; asks = Levels.create ()
  ; bids = Levels.create ()
  }
;;

let[@zero_alloc] find_key s ~from ~until key =
  let k = String.length key in
  let first = String.unsafe_get key 0 in
  let until = Int.min until (String.length s) in
  let mutable i = Int.max from 0 in
  let mutable found = -1 in
  while found < 0 && i + k <= until do
    if not (Char.equal (String.unsafe_get s i) first)
    then i <- i + 1
    else (
      let mutable j = 1 in
      while j < k && Char.equal (String.unsafe_get s (i + j)) (String.unsafe_get key j) do
        j <- j + 1
      done;
      if j = k then found <- i + k else i <- i + 1)
  done;
  found
;;

let[@zero_alloc] substring_equal s ~pos ~len t =
  if len <> String.length t || pos < 0 || pos + len > String.length s
  then false
  else (
    let mutable i = 0 in
    while i < len && Char.equal (String.unsafe_get s (pos + i)) (String.unsafe_get t i) do
      i <- i + 1
    done;
    i = len)
;;

(* Position after [lit] if [s] has it at [pos], else [-1]. *)
let[@zero_alloc] expect s pos lit =
  if pos >= 0 && substring_equal s ~pos ~len:(String.length lit) lit
  then pos + String.length lit
  else -1
;;

(* The next ['"'] at or after [pos], or [-1]. Escapes are rejected up front by
   [plain_shape]. *)
let[@zero_alloc] string_end s pos =
  let n = String.length s in
  let mutable i = if pos < 0 then n else pos in
  while i < n && not (Char.equal (String.unsafe_get s i) '"') do
    i <- i + 1
  done;
  if i < n then i else -1
;;

(* No escapes, exactly three objects (the frame, [arg] and the one [data] entry, so no
   string holds a brace), and the frame ends with the entry and the [data] array. *)
let[@zero_alloc] plain_shape s =
  let n = String.length s in
  let mutable opens = 0 in
  let mutable closes = 0 in
  let mutable escapes = 0 in
  for i = 0 to n - 1 do
    match String.unsafe_get s i with
    | '{' -> opens <- opens + 1
    | '}' -> closes <- closes + 1
    | '\\' -> escapes <- escapes + 1
    | _ -> ()
  done;
  escapes = 0 && opens = 3 && closes = 3 && expect s (n - 3) "}]}" = n
;;

let[@zero_alloc] decimal s pos =
  let n = String.length s in
  let mutable i = pos in
  let mutable whole = 0 in
  let mutable int_digits = 0 in
  while i < n && Char.is_digit (String.unsafe_get s i) do
    whole <- (whole * 10) + (Char.to_int (String.unsafe_get s i) - 48);
    int_digits <- int_digits + 1;
    i <- i + 1
  done;
  let mutable frac = 0 in
  let mutable frac_digits = 0 in
  let mutable dot = false in
  if i < n && Char.equal (String.unsafe_get s i) '.'
  then (
    dot <- true;
    i <- i + 1;
    while i < n && Char.is_digit (String.unsafe_get s i) do
      if frac_digits < 8
      then frac <- (frac * 10) + (Char.to_int (String.unsafe_get s i) - 48);
      frac_digits <- frac_digits + 1;
      i <- i + 1
    done);
  if int_digits = 0
     || int_digits > 10
     || (dot && frac_digits = 0)
     || i >= n
     || not (Char.equal (String.unsafe_get s i) '"')
  then -1
  else (
    let mutable f = Int.min frac_digits 8 in
    while f < 8 do
      frac <- frac * 10;
      f <- f + 1
    done;
    (whole * 100_000_000) + frac)
;;

(* A quoted non-negative integer of 1 to 18 digits at [pos] (just after the quote), or
   [-1]. *)
let[@zero_alloc] quoted_int s pos =
  let n = String.length s in
  let mutable i = pos in
  let mutable v = 0 in
  while i < n && Char.is_digit (String.unsafe_get s i) do
    v <- (v * 10) + (Char.to_int (String.unsafe_get s i) - 48);
    i <- i + 1
  done;
  let digits = i - pos in
  if digits = 0 || digits > 18 || i >= n || not (Char.equal (String.unsafe_get s i) '"')
  then -1
  else v
;;

(* A bare integer of 1 to 18 digits, optionally negative, ended by [,] or [}]; else
   [Int.min_value]. *)
let[@zero_alloc] bare_int s pos =
  let n = String.length s in
  let negative = pos < n && Char.equal (String.unsafe_get s pos) '-' in
  let start = if negative then pos + 1 else pos in
  let mutable i = start in
  let mutable v = 0 in
  while i < n && Char.is_digit (String.unsafe_get s i) do
    v <- (v * 10) + (Char.to_int (String.unsafe_get s i) - 48);
    i <- i + 1
  done;
  let digits = i - start in
  if digits = 0
     || digits > 18
     || i >= n
     || not
          (Char.equal (String.unsafe_get s i) ','
           || Char.equal (String.unsafe_get s i) '}')
  then Int.min_value
  else if negative
  then -v
  else v
;;

(* A side's levels: [[["px","sz",...strings],...]] at [pos] into [l]. Returns the position
   after the closing bracket, or [-1]. *)
let[@zero_alloc] levels s pos (l : Levels.t) =
  let n = String.length s in
  l.n <- 0;
  l.full <- false;
  let mutable i = pos + 1 in
  let mutable ok = pos >= 0 && pos < n && Char.equal (String.unsafe_get s pos) '[' in
  let mutable fin = false in
  if ok && i < n && Char.equal (String.unsafe_get s i) ']'
  then (
    fin <- true;
    i <- i + 1);
  while ok && not fin do
    let p = expect s i {|["|} in
    let px = if p < 0 then -1 else decimal s p in
    let e1 = if px < 0 then -1 else string_end s p in
    let q = if e1 < 0 then -1 else expect s (e1 + 1) {|,"|} in
    let sz = if q < 0 then -1 else decimal s q in
    let e2 = if sz < 0 then -1 else string_end s q in
    if e2 < 0
    then ok <- false
    else if l.n >= Array.length l.px
    then (
      l.full <- true;
      ok <- false)
    else (
      Array.unsafe_set l.px l.n px;
      Array.unsafe_set l.sz l.n sz;
      l.n <- l.n + 1;
      (* The other strings of the level, then [,] or the end of the side. *)
      i <- e2 + 1;
      let mutable inner = true in
      while ok && inner do
        if i < n && Char.equal (String.unsafe_get s i) ']'
        then (
          inner <- false;
          i <- i + 1)
        else (
          let r = expect s i {|,"|} in
          let e = if r < 0 then -1 else string_end s r in
          if e < 0 then ok <- false else i <- e + 1)
      done;
      if ok
      then
        if i < n && Char.equal (String.unsafe_get s i) ','
        then i <- i + 1
        else if i < n && Char.equal (String.unsafe_get s i) ']'
        then (
          fin <- true;
          i <- i + 1)
        else ok <- false)
  done;
  if ok then i else -1
;;

let[@zero_alloc] trade s (t : trade) =
  let p = expect s 0 {|{"arg":{"channel":"trades","instId":"|} in
  if p < 0 || not (plain_shape s)
  then false
  else (
    let e = string_end s p in
    let obj = if e < 0 then -1 else expect s e {|"},"data":[{|} in
    if obj < 0
    then false
    else (
      let until = String.length s - 3 in
      let inst = find_key s ~from:obj ~until {|"instId":"|} in
      let id = find_key s ~from:obj ~until {|"tradeId":"|} in
      let px = find_key s ~from:obj ~until {|"px":"|} in
      let sz = find_key s ~from:obj ~until {|"sz":"|} in
      let side = find_key s ~from:obj ~until {|"side":"|} in
      let ts = find_key s ~from:obj ~until {|"ts":"|} in
      if inst < 0 || id < 0 || px < 0 || sz < 0 || side < 0 || ts < 0
      then false
      else (
        let inst_end = string_end s inst in
        let id_end = string_end s id in
        let px = decimal s px in
        let sz = decimal s sz in
        let ts = quoted_int s ts in
        let buy = expect s side {|buy"|} >= 0 in
        let sell = expect s side {|sell"|} >= 0 in
        if inst_end < 0 || id_end < 0 || px < 0 || sz < 0 || ts < 0 || not (buy || sell)
        then false
        else (
          t.inst_pos <- inst;
          t.inst_len <- inst_end - inst;
          t.trade_id_pos <- id;
          t.trade_id_len <- id_end - id;
          t.px <- px;
          t.sz <- sz;
          t.buy <- buy;
          t.ts <- ts;
          true))))
;;

(* [asks], [bids] and [ts] of the one entry starting at [obj]. *)
let[@zero_alloc] book_entry s ~obj (b : book) =
  let until = String.length s - 3 in
  let asks = find_key s ~from:obj ~until {|"asks":|} in
  let bids = find_key s ~from:obj ~until {|"bids":|} in
  let ts = find_key s ~from:obj ~until {|"ts":"|} in
  if asks < 0 || bids < 0 || ts < 0
  then false
  else (
    let ts = quoted_int s ts in
    ts >= 0
    && levels s asks b.asks >= 0
    && levels s bids b.bids >= 0
    &&
    (b.ts <- ts;
     true))
;;

let[@zero_alloc] bbo s (b : book) =
  let p = expect s 0 {|{"arg":{"channel":"bbo-tbt","instId":"|} in
  if p < 0 || not (plain_shape s)
  then false
  else (
    let e = string_end s p in
    let obj = if e < 0 then -1 else expect s e {|"},"data":[{|} in
    if obj < 0 || not (book_entry s ~obj b)
    then false
    else (
      b.channel_pos <- 19;
      b.channel_len <- 7;
      b.inst_pos <- p;
      b.inst_len <- e - p;
      true))
;;

let[@zero_alloc] book s (b : book) =
  let channel = expect s 0 {|{"arg":{"channel":"books|} in
  if channel < 0 || not (plain_shape s)
  then false
  else (
    let channel_end = string_end s channel in
    let inst = if channel_end < 0 then -1 else expect s channel_end {|","instId":"|} in
    let inst_end = string_end s inst in
    let action = if inst_end < 0 then -1 else expect s inst_end {|"},"action":"|} in
    let snapshot = expect s action {|snapshot"|} in
    let update = if snapshot >= 0 then -1 else expect s action {|update"|} in
    let after_action = if snapshot >= 0 then snapshot else update in
    let obj = if after_action < 0 then -1 else expect s after_action {|,"data":[{|} in
    if obj < 0 || not (book_entry s ~obj b)
    then false
    else (
      let until = String.length s - 3 in
      let seq = find_key s ~from:obj ~until {|"seqId":|} in
      let prev = find_key s ~from:obj ~until {|"prevSeqId":|} in
      let seq = if seq < 0 then Int.min_value else bare_int s seq in
      let prev = if prev < 0 then Int.min_value else bare_int s prev in
      if seq = Int.min_value || prev = Int.min_value
      then false
      else (
        b.channel_pos <- 19;
        b.channel_len <- channel_end - 19;
        b.inst_pos <- inst;
        b.inst_len <- inst_end - inst;
        b.snapshot <- snapshot >= 0;
        b.seq_id <- seq;
        b.prev_seq_id <- prev;
        true)))
;;

let full (b : book) = b.asks.full || b.bids.full

let grow (b : book) =
  Levels.grow b.asks;
  Levels.grow b.bids
;;
