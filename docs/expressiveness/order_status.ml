(* "Make illegal states unrepresentable."

   A live order always has a remaining quantity; a finished order has a reason and NO remaining
   quantity. Modelling them as one sum type means you can never build nonsense like a "filled
   order with 7 shares remaining", and `cancel`/`fill` can only be applied to a live order
   (they take the [live] record, not the [order] sum), so cancelling a finished order is a
   *type error*, not a runtime check. Compare the bad design:

     type order_bad = { filled : bool; cancelled : bool; remaining : int }
     (* filled && cancelled, or filled with remaining > 0, are all representable + meaningless *)
*)

type live = { id : int; price : int; remaining : int }
type done_reason = Filled | Cancelled
type order =
  | Live of live
  | Done of done_reason

let cancel (_o : live) : order = Done Cancelled

let fill (o : live) ~qty : order =
  if qty >= o.remaining then Done Filled else Live { o with remaining = o.remaining - qty }

(* Exhaustive by construction: every status must be handled or the compiler complains. *)
let status_label = function
  | Live l -> Printf.sprintf "live(%d@%d)" l.remaining l.price
  | Done Filled -> "filled"
  | Done Cancelled -> "cancelled"

let () =
  let o = Live { id = 1; price = 100; remaining = 10 } in
  let o = match o with Live l -> fill l ~qty:4 | d -> d in
  print_endline (status_label o)
