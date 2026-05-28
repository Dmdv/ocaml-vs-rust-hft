(* This file intentionally does NOT type-check. It documents a class of bug the type system
   rejects at compile time. Reproduce: ocamlopt -c illegal_fail.ml *)

type live = { id : int; price : int; remaining : int }
type done_reason = Filled | Cancelled
type order =
  | Live of live
  | Done of done_reason

let cancel (_o : live) : order = Done Cancelled

(* Bug: trying to cancel an order that is already finished. `cancel` wants a [live] record, but
   [Done Filled] has type [order]. The mistake cannot reach runtime — it does not compile. *)
let _ = cancel (Done Filled)
