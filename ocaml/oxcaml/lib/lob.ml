(* Limit-order-book matching engine — zero-allocation OCaml, built on the OxCaml/flambda2
   toolchain.

   Same algorithm as the idiomatic version, but the representation is flattened so the hot path
   allocates nothing and never triggers the GC:
     - order nodes live in ONE strided [int array] (6 ints per node, contiguous), so a node's
       fields share a cache line — the layout an OxCaml unboxed record array would give you, and
       what Rust's `Vec<Node>` gives. (Struct-of-arrays would scatter a node across 6 cache
       lines, which hurts the pointer-chasing FIFO walk.)
     - id -> slot uses a custom open-addressing int->int map (below), so lookups return a plain
       int (-1 if absent) with no [option] boxing and no bucket cons.

   For an int-keyed book this is expressible in stock OCaml (ints are already unboxed); OxCaml's
   contribution is making the discipline *ergonomic and machine-checked* — its mode system can
   prove a function never heap-allocates, and unboxed records would give this exact flat layout
   with record syntax instead of manual offset arithmetic. Digest uses Int64 to match Rust. *)

let max_price = 20_000
let side_bid = 0
let side_ask = 1
let nil = -1

(* Open-addressing int->int map: linear probing with backward-shift deletion (no tombstones),
   so probe chains stay short under heavy insert/cancel churn. Zero-allocation lookups. *)
module Imap = struct
  type t = {
    mutable keys : int array;
    mutable vals : int array;
    mutable mask : int;
    mutable count : int;
  }

  let empty = -1

  let create n =
    let cap = ref 16 in
    while !cap < n * 2 do
      cap := !cap * 2
    done;
    { keys = Array.make !cap empty; vals = Array.make !cap 0; mask = !cap - 1; count = 0 }

  let[@inline] hash k mask = k * 0x9E3779B1 land mask

  let find t k =
    let mask = t.mask in
    let i = ref (hash k mask) in
    let res = ref (-1) in
    let go = ref true in
    while !go do
      let kk = t.keys.(!i) in
      if kk = empty then (res := -1; go := false)
      else if kk = k then (res := t.vals.(!i); go := false)
      else i := (!i + 1) land mask
    done;
    !res

  let rec insert t k v =
    if (t.count + 1) * 4 >= (t.mask + 1) * 3 then resize t;
    let mask = t.mask in
    let i = ref (hash k mask) in
    let go = ref true in
    while !go do
      let kk = t.keys.(!i) in
      if kk = empty then (t.keys.(!i) <- k; t.vals.(!i) <- v; t.count <- t.count + 1; go := false)
      else if kk = k then (t.vals.(!i) <- v; go := false)
      else i := (!i + 1) land mask
    done

  and resize t =
    let ok = t.keys and ov = t.vals in
    let ncap = (t.mask + 1) * 2 in
    t.keys <- Array.make ncap empty;
    t.vals <- Array.make ncap 0;
    t.mask <- ncap - 1;
    t.count <- 0;
    for j = 0 to Array.length ok - 1 do
      if ok.(j) <> empty then insert t ok.(j) ov.(j)
    done

  (* Backward-shift deletion: refill the gap from later entries whose home slot precedes it. *)
  let remove t k =
    let mask = t.mask in
    let p = ref (hash k mask) in
    while t.keys.(!p) <> empty && t.keys.(!p) <> k do
      p := (!p + 1) land mask
    done;
    if t.keys.(!p) = k then begin
      t.count <- t.count - 1;
      let i = ref !p and j = ref !p in
      let return = ref false in
      while not !return do
        t.keys.(!i) <- empty;
        let moved = ref false in
        while (not !moved) && (not !return) do
          j := (!j + 1) land mask;
          if t.keys.(!j) = empty then return := true
          else begin
            let kh = hash t.keys.(!j) mask in
            let keep = if !i <= !j then !i < kh && kh <= !j else !i < kh || kh <= !j in
            if not keep then begin
              t.keys.(!i) <- t.keys.(!j);
              t.vals.(!i) <- t.vals.(!j);
              i := !j;
              moved := true
            end
          end
        done
      done
    end

  let length t = t.count
end

(* A node occupies [nfields] contiguous ints in [na]; node i starts at i*nfields. *)
let nfields = 6
let f_id = 0
let f_side = 1
let f_price = 2
let f_qty = 3
let f_prev = 4
let f_next = 5

type t = {
  mutable na : int array; (* strided node arena *)
  mutable cap : int; (* capacity in nodes *)
  mutable len : int;
  mutable free : int array;
  mutable free_n : int;
  bids_head : int array;
  bids_tail : int array;
  asks_head : int array;
  asks_tail : int array;
  idmap : Imap.t;
  mutable bb : int;
  mutable ba : int;
  mutable tr_maker : int array;
  mutable tr_taker : int array;
  mutable tr_price : int array;
  mutable tr_qty : int array;
  mutable tr_aggr : int array;
  mutable tr_n : int;
}

let create ?(trade_cap = 256) ?(orders = 1 lsl 16) () =
  let c = 1 lsl 16 in
  {
    na = Array.make (c * nfields) 0;
    cap = c;
    len = 0;
    free = Array.make 1024 0;
    free_n = 0;
    bids_head = Array.make max_price nil;
    bids_tail = Array.make max_price nil;
    asks_head = Array.make max_price nil;
    asks_tail = Array.make max_price nil;
    idmap = Imap.create orders;
    bb = -1;
    ba = max_price;
    tr_maker = Array.make trade_cap 0;
    tr_taker = Array.make trade_cap 0;
    tr_price = Array.make trade_cap 0;
    tr_qty = Array.make trade_cap 0;
    tr_aggr = Array.make trade_cap 0;
    tr_n = 0;
  }

let clear_trades t = t.tr_n <- 0

let grow_nodes t =
  let ncap = t.cap * 2 in
  let b = Array.make (ncap * nfields) 0 in
  Array.blit t.na 0 b 0 (t.len * nfields);
  t.na <- b;
  t.cap <- ncap

let alloc t id side price qty =
  let i =
    if t.free_n > 0 then begin
      t.free_n <- t.free_n - 1;
      t.free.(t.free_n)
    end
    else begin
      if t.len >= t.cap then grow_nodes t;
      let i = t.len in
      t.len <- t.len + 1;
      i
    end
  in
  let b = i * nfields in
  t.na.(b + f_id) <- id;
  t.na.(b + f_side) <- side;
  t.na.(b + f_price) <- price;
  t.na.(b + f_qty) <- qty;
  t.na.(b + f_prev) <- nil;
  t.na.(b + f_next) <- nil;
  i

let free_node t i =
  if t.free_n >= Array.length t.free then begin
    let b = Array.make (Array.length t.free * 2) 0 in
    Array.blit t.free 0 b 0 t.free_n;
    t.free <- b
  end;
  t.free.(t.free_n) <- i;
  t.free_n <- t.free_n + 1

let grow_trades t =
  let ncap = Array.length t.tr_maker * 2 in
  let g a =
    let b = Array.make ncap 0 in
    Array.blit a 0 b 0 t.tr_n;
    b
  in
  t.tr_maker <- g t.tr_maker;
  t.tr_taker <- g t.tr_taker;
  t.tr_price <- g t.tr_price;
  t.tr_qty <- g t.tr_qty;
  t.tr_aggr <- g t.tr_aggr

let[@inline] emit t maker taker price qty aggr =
  if t.tr_n >= Array.length t.tr_maker then grow_trades t;
  let i = t.tr_n in
  t.tr_maker.(i) <- maker;
  t.tr_taker.(i) <- taker;
  t.tr_price.(i) <- price;
  t.tr_qty.(i) <- qty;
  t.tr_aggr.(i) <- aggr;
  t.tr_n <- i + 1

let advance_best_ask t =
  let p = ref (t.ba + 1) in
  while !p < max_price && t.asks_head.(!p) = nil do
    incr p
  done;
  t.ba <- (if !p < max_price then !p else max_price)

let advance_best_bid t =
  let p = ref (t.bb - 1) in
  while !p >= 1 && t.bids_head.(!p) = nil do
    decr p
  done;
  t.bb <- (if !p >= 1 then !p else -1)

let rest t id side price qty =
  let idx = alloc t id side price qty in
  if side = side_bid then begin
    let tail = t.bids_tail.(price) in
    if tail = nil then (t.bids_head.(price) <- idx; t.bids_tail.(price) <- idx)
    else (t.na.((tail * nfields) + f_next) <- idx; t.na.((idx * nfields) + f_prev) <- tail; t.bids_tail.(price) <- idx);
    if price > t.bb then t.bb <- price
  end
  else begin
    let tail = t.asks_tail.(price) in
    if tail = nil then (t.asks_head.(price) <- idx; t.asks_tail.(price) <- idx)
    else (t.na.((tail * nfields) + f_next) <- idx; t.na.((idx * nfields) + f_prev) <- tail; t.asks_tail.(price) <- idx);
    if price < t.ba then t.ba <- price
  end;
  Imap.insert t.idmap id idx

let cross t side taker qty limit =
  let qty = ref qty in
  if side = side_bid then begin
    let go = ref true in
    while !go && !qty > 0 do
      let ba = t.ba in
      if ba >= max_price || ba > limit then go := false
      else begin
        let inner = ref true in
        while !inner && !qty > 0 do
          let h = t.asks_head.(ba) in
          if h = nil then inner := false
          else begin
            let b = h * nfields in
            let nq = t.na.(b + f_qty) in
            let traded = if !qty < nq then !qty else nq in
            t.na.(b + f_qty) <- nq - traded;
            qty := !qty - traded;
            emit t t.na.(b + f_id) taker ba traded side_bid;
            if nq - traded = 0 then begin
              let nxt = t.na.(b + f_next) in
              t.asks_head.(ba) <- nxt;
              if nxt = nil then t.asks_tail.(ba) <- nil else t.na.((nxt * nfields) + f_prev) <- nil;
              Imap.remove t.idmap t.na.(b + f_id);
              free_node t h
            end
          end
        done;
        if t.asks_head.(ba) = nil then advance_best_ask t
      end
    done
  end
  else begin
    let go = ref true in
    while !go && !qty > 0 do
      let bb = t.bb in
      if bb < 0 || bb < limit then go := false
      else begin
        let inner = ref true in
        while !inner && !qty > 0 do
          let h = t.bids_head.(bb) in
          if h = nil then inner := false
          else begin
            let b = h * nfields in
            let nq = t.na.(b + f_qty) in
            let traded = if !qty < nq then !qty else nq in
            t.na.(b + f_qty) <- nq - traded;
            qty := !qty - traded;
            emit t t.na.(b + f_id) taker bb traded side_ask;
            if nq - traded = 0 then begin
              let nxt = t.na.(b + f_next) in
              t.bids_head.(bb) <- nxt;
              if nxt = nil then t.bids_tail.(bb) <- nil else t.na.((nxt * nfields) + f_prev) <- nil;
              Imap.remove t.idmap t.na.(b + f_id);
              free_node t h
            end
          end
        done;
        if t.bids_head.(bb) = nil then advance_best_bid t
      end
    done
  end;
  !qty

let unlink_and_free t idx =
  let b = idx * nfields in
  let side = t.na.(b + f_side) and price = t.na.(b + f_price) in
  let prev = t.na.(b + f_prev) and next = t.na.(b + f_next) in
  if prev <> nil then t.na.((prev * nfields) + f_next) <- next;
  if next <> nil then t.na.((next * nfields) + f_prev) <- prev;
  let emptied =
    if side = side_bid then begin
      if t.bids_head.(price) = idx then t.bids_head.(price) <- next;
      if t.bids_tail.(price) = idx then t.bids_tail.(price) <- prev;
      t.bids_head.(price) = nil
    end
    else begin
      if t.asks_head.(price) = idx then t.asks_head.(price) <- next;
      if t.asks_tail.(price) = idx then t.asks_tail.(price) <- prev;
      t.asks_head.(price) = nil
    end
  in
  free_node t idx;
  if emptied then begin
    if side = side_bid && t.bb = price then advance_best_bid t;
    if side = side_ask && t.ba = price then advance_best_ask t
  end

let handle_limit t side id price qty =
  let rem = cross t side id qty price in
  if rem > 0 then rest t id side price rem

let handle_market t side id qty =
  let limit = if side = side_bid then max_int else 0 in
  ignore (cross t side id qty limit : int)

let handle_cancel t id =
  let idx = Imap.find t.idmap id in
  if idx >= 0 then begin
    unlink_and_free t idx;
    Imap.remove t.idmap id
  end

let handle_replace t id new_price new_qty =
  let idx = Imap.find t.idmap id in
  if idx >= 0 then begin
    let b = idx * nfields in
    let price = t.na.(b + f_price) and qty = t.na.(b + f_qty) in
    if new_price = price && new_qty > 0 && new_qty <= qty then t.na.(b + f_qty) <- new_qty
    else begin
      let side = t.na.(b + f_side) in
      unlink_and_free t idx;
      Imap.remove t.idmap id;
      if new_qty > 0 then handle_limit t side id new_price new_qty
    end
  end

let[@inline] process t mtype side id price qty nprice nqty =
  match mtype with
  | 0 -> handle_limit t side id price qty
  | 3 -> handle_market t side id qty
  | 1 -> handle_cancel t id
  | 2 -> handle_replace t id nprice nqty
  | _ -> ()

let digest t =
  let prime = 0x100000001b3L in
  let h = ref 0xcbf29ce484222325L in
  let feed_u32 v =
    for k = 0 to 3 do
      let by = (v lsr (k * 8)) land 0xff in
      h := Int64.mul (Int64.logxor !h (Int64.of_int by)) prime
    done
  in
  let feed_byte by = h := Int64.mul (Int64.logxor !h (Int64.of_int by)) prime in
  let walk head =
    for p = 0 to max_price - 1 do
      let cur = ref head.(p) in
      while !cur <> nil do
        let b = !cur * nfields in
        feed_u32 t.na.(b + f_id);
        feed_byte t.na.(b + f_side);
        feed_u32 t.na.(b + f_price);
        feed_u32 t.na.(b + f_qty);
        cur := t.na.(b + f_next)
      done
    done
  in
  walk t.bids_head;
  walk t.asks_head;
  !h

let best_bid t = if t.bb >= 0 then Some t.bb else None
let best_ask t = if t.ba < max_price then Some t.ba else None
let resting_count t = Imap.length t.idmap
let order_qty t id =
  let i = Imap.find t.idmap id in
  if i >= 0 then Some t.na.((i * nfields) + f_qty) else None
