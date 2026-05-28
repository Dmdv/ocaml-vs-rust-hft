(* The "ultimate refactoring tool": add a new order kind, and the compiler points at EVERY
   match that no longer handles all cases — before any test runs. Reproduce:
     ocamlopt -c iceberg_refactor.ml
   (warning 8: this pattern-matching is not exhaustive; "Iceberg _" is unmatched). *)

type live = { id : int; price : int; remaining : int }
type done_reason = Filled | Cancelled
type order =
  | Live of live
  | Done of done_reason
  | Iceberg of { shown : int; hidden : int } (* NEW: only `shown` is visible to the book *)

(* This function predates `Iceberg` and was not updated — the compiler flags it for us. *)
let status_label = function
  | Live l -> Printf.sprintf "live(%d@%d)" l.remaining l.price
  | Done Filled -> "filled"
  | Done Cancelled -> "cancelled"
