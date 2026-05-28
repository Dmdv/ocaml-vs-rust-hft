(* Limit-order-book matching engine — idiomatic OCaml.

   Same algorithm and data layout as the Rust baseline (array price ladder, index-arena
   intrusive FIFO, Hashtbl id->slot), so the variable under test is *representation*:
   here each resting order is a heap-boxed mutable record stored in a [node array] (an array of
   pointers). That is the natural, ergonomic OCaml style — and it allocates one record per
   resting order, which is exactly the GC pressure the OxCaml version removes.

   See spec/protocol.md for the contract. The digest uses Int64 to match Rust's wrapping u64. *)

let max_price = 20_000
let side_bid = 0
let side_ask = 1
let nil = -1

type node = {
  id : int;
  side : int;
  price : int;
  mutable qty : int;
  mutable prev : int;
  mutable next : int;
}

let dummy = { id = -1; side = -1; price = -1; qty = 0; prev = nil; next = nil }

type t = {
  mutable nodes : node array; (* arena; slots reused via the freelist *)
  mutable cap : int;
  mutable len : int;
  mutable free : int array;
  mutable free_n : int;
  bids_head : int array;
  bids_tail : int array;
  asks_head : int array;
  asks_tail : int array;
  id_tbl : (int, int) Hashtbl.t;
  mutable bb : int; (* best bid price, -1 when none *)
  mutable ba : int; (* best ask price, max_price when none *)
  (* trade output buffer (struct-of-arrays; not the representation variable, kept alloc-free) *)
  mutable tr_maker : int array;
  mutable tr_taker : int array;
  mutable tr_price : int array;
  mutable tr_qty : int array;
  mutable tr_aggr : int array;
  mutable tr_n : int;
}

let create ?(trade_cap = 256) () =
  {
    nodes = Array.make (1 lsl 16) dummy;
    cap = 1 lsl 16;
    len = 0;
    free = Array.make 1024 0;
    free_n = 0;
    bids_head = Array.make max_price nil;
    bids_tail = Array.make max_price nil;
    asks_head = Array.make max_price nil;
    asks_tail = Array.make max_price nil;
    id_tbl = Hashtbl.create (1 lsl 16);
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
  let a = Array.make ncap dummy in
  Array.blit t.nodes 0 a 0 t.len;
  t.nodes <- a;
  t.cap <- ncap

let alloc t node =
  if t.free_n > 0 then begin
    t.free_n <- t.free_n - 1;
    let i = t.free.(t.free_n) in
    t.nodes.(i) <- node;
    i
  end
  else begin
    if t.len >= t.cap then grow_nodes t;
    let i = t.len in
    t.nodes.(i) <- node;
    t.len <- t.len + 1;
    i
  end

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
  let idx = alloc t { id; side; price; qty; prev = nil; next = nil } in
  if side = side_bid then begin
    let tail = t.bids_tail.(price) in
    if tail = nil then begin
      t.bids_head.(price) <- idx;
      t.bids_tail.(price) <- idx
    end
    else begin
      t.nodes.(tail).next <- idx;
      t.nodes.(idx).prev <- tail;
      t.bids_tail.(price) <- idx
    end;
    if price > t.bb then t.bb <- price
  end
  else begin
    let tail = t.asks_tail.(price) in
    if tail = nil then begin
      t.asks_head.(price) <- idx;
      t.asks_tail.(price) <- idx
    end
    else begin
      t.nodes.(tail).next <- idx;
      t.nodes.(idx).prev <- tail;
      t.asks_tail.(price) <- idx
    end;
    if price < t.ba then t.ba <- price
  end;
  Hashtbl.replace t.id_tbl id idx

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
            let node = t.nodes.(h) in
            let traded = if !qty < node.qty then !qty else node.qty in
            node.qty <- node.qty - traded;
            qty := !qty - traded;
            emit t node.id taker ba traded side_bid;
            if node.qty = 0 then begin
              let nxt = node.next in
              t.asks_head.(ba) <- nxt;
              if nxt = nil then t.asks_tail.(ba) <- nil else t.nodes.(nxt).prev <- nil;
              Hashtbl.remove t.id_tbl node.id;
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
            let node = t.nodes.(h) in
            let traded = if !qty < node.qty then !qty else node.qty in
            node.qty <- node.qty - traded;
            qty := !qty - traded;
            emit t node.id taker bb traded side_ask;
            if node.qty = 0 then begin
              let nxt = node.next in
              t.bids_head.(bb) <- nxt;
              if nxt = nil then t.bids_tail.(bb) <- nil else t.nodes.(nxt).prev <- nil;
              Hashtbl.remove t.id_tbl node.id;
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
  let node = t.nodes.(idx) in
  let side = node.side and price = node.price and prev = node.prev and next = node.next in
  if prev <> nil then t.nodes.(prev).next <- next;
  if next <> nil then t.nodes.(next).prev <- prev;
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
  match Hashtbl.find_opt t.id_tbl id with
  | None -> ()
  | Some idx ->
    unlink_and_free t idx;
    Hashtbl.remove t.id_tbl id

let handle_replace t id new_price new_qty =
  match Hashtbl.find_opt t.id_tbl id with
  | None -> ()
  | Some idx ->
    let node = t.nodes.(idx) in
    if new_price = node.price && new_qty > 0 && new_qty <= node.qty then node.qty <- new_qty
    else begin
      let side = node.side in
      unlink_and_free t idx;
      Hashtbl.remove t.id_tbl id;
      if new_qty > 0 then handle_limit t side id new_price new_qty
    end

let[@inline] process t mtype side id price qty nprice nqty =
  match mtype with
  | 0 -> handle_limit t side id price qty
  | 3 -> handle_market t side id qty
  | 1 -> handle_cancel t id
  | 2 -> handle_replace t id nprice nqty
  | _ -> ()

(* FNV-1a-64 over the canonicalized resting book (spec §4); Int64 to match Rust's wrapping u64. *)
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
        let n = t.nodes.(!cur) in
        feed_u32 n.id;
        feed_byte n.side;
        feed_u32 n.price;
        feed_u32 n.qty;
        cur := n.next
      done
    done
  in
  walk t.bids_head;
  walk t.asks_head;
  !h

let best_bid t = if t.bb >= 0 then Some t.bb else None
let best_ask t = if t.ba < max_price then Some t.ba else None
let resting_count t = Hashtbl.length t.id_tbl
let order_qty t id = Option.map (fun i -> t.nodes.(i).qty) (Hashtbl.find_opt t.id_tbl id)
