open Lob

(* Process one message and return the trades it produced as (maker,taker,price,qty,aggr) tuples. *)
let step b mtype side id price qty nprice nqty =
  clear_trades b;
  process b mtype side id price qty nprice nqty;
  List.init b.tr_n (fun i -> (b.tr_maker.(i), b.tr_taker.(i), b.tr_price.(i), b.tr_qty.(i), b.tr_aggr.(i)))

let () =
  (* add rests without crossing *)
  let b = create () in
  assert (step b 0 side_bid 1 100 10 0 0 = []);
  assert (best_bid b = Some 100);
  assert (best_ask b = None);
  assert (resting_count b = 1);

  (* crossing limit: partial fill at the maker (resting) price *)
  let b = create () in
  ignore (step b 0 side_ask 1 100 5 0 0);
  assert (step b 0 side_bid 2 105 3 0 0 = [ (1, 2, 100, 3, side_bid) ]);
  assert (order_qty b 1 = Some 2);
  assert (best_ask b = Some 100);
  assert (best_bid b = None);

  (* sweep multiple levels in price-then-time priority *)
  let b = create () in
  ignore (step b 0 side_ask 1 100 2 0 0);
  ignore (step b 0 side_ask 2 101 2 0 0);
  assert (step b 0 side_bid 3 101 3 0 0 = [ (1, 3, 100, 2, side_bid); (2, 3, 101, 1, side_bid) ]);
  assert (order_qty b 2 = Some 1);

  (* fifo time priority within one level *)
  let b = create () in
  ignore (step b 0 side_ask 1 100 2 0 0);
  ignore (step b 0 side_ask 2 100 2 0 0);
  assert (step b 0 side_bid 3 100 3 0 0 = [ (1, 3, 100, 2, side_bid); (2, 3, 100, 1, side_bid) ]);
  assert (order_qty b 1 = None);
  assert (order_qty b 2 = Some 1);

  (* market consumes available then discards the remainder *)
  let b = create () in
  ignore (step b 0 side_ask 1 100 2 0 0);
  assert (step b 3 side_bid 9 0 5 0 0 = [ (1, 9, 100, 2, side_bid) ]);
  assert (resting_count b = 0);

  (* market on empty book is a no-op *)
  let b = create () in
  assert (step b 3 side_ask 9 0 5 0 0 = []);

  (* cancel present and absent *)
  let b = create () in
  ignore (step b 0 side_bid 1 100 10 0 0);
  ignore (step b 0 side_bid 2 99 10 0 0);
  ignore (step b 1 0 1 0 0 0 0);
  assert (order_qty b 1 = None);
  assert (best_bid b = Some 99);
  ignore (step b 1 0 999 0 0 0 0);
  assert (resting_count b = 1);

  (* replace size-down keeps time priority *)
  let b = create () in
  ignore (step b 0 side_ask 1 100 5 0 0);
  ignore (step b 0 side_ask 2 100 5 0 0);
  ignore (step b 2 0 1 0 0 100 2);
  assert (order_qty b 1 = Some 2);
  assert (step b 0 side_bid 3 100 2 0 0 = [ (1, 3, 100, 2, side_bid) ]);

  (* replace with price change loses priority and can cross *)
  let b = create () in
  ignore (step b 0 side_bid 1 100 5 0 0);
  ignore (step b 0 side_ask 2 105 5 0 0);
  assert (step b 2 0 1 0 0 105 5 = [ (2, 1, 105, 5, side_bid) ]);
  assert (resting_count b = 0);

  print_string "ocaml idiomatic tests passed\n"
