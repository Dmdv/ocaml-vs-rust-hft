# Expressiveness: the other half of "why OCaml"

Latency is only one leg of Jane Street's case for OCaml. The other — the one their engineers
talk about most — is that a strong, lightweight type system lets a large team **change code
fearlessly**. This directory makes that concrete with tiny programs you can compile yourself.

Honest framing up front: **Rust's type system is also excellent** at both things below. The
difference is *ceremony*, not capability — OCaml expresses these patterns with sum types, inline
records and type inference, and no borrow-checker friction for plain value types. The point of
this demo is to show the mechanism is real, in both languages.

## 1. Make illegal states unrepresentable

`order_status.ml` models an order as a sum type: a `Live` order *always* carries a remaining
quantity; a `Done` order carries a reason and has *no* quantity field. Whole classes of bug —
"a filled order with 7 shares left", "an order that is both filled and cancelled" — simply
cannot be constructed. And because `cancel`/`fill` take the `live` record (not the `order` sum),
**cancelling an already-finished order is a compile error**, not a runtime check.

`illegal_fail.ml` tries exactly that bug:

```ocaml
let cancel (_o : live) : order = Done Cancelled
let _ = cancel (Done Filled)   (* a finished order is not live *)
```

```
$ ocamlopt -c illegal_fail.ml
File "illegal_fail.ml", line 14, characters 15-28:
14 | let _ = cancel (Done Filled)
                    ^^^^^^^^^^^^^
Error: This expression should not be a constructor, the expected type is live
```

The mistake cannot reach production — it cannot even build.

## 2. The "ultimate refactoring tool"

Jane Street's most-repeated practical claim: the type system turns a scary refactor into a
mechanical one. Add a field or a case, and the compiler walks you to **every** site that must
change. `iceberg_refactor.ml` adds a hidden-quantity `Iceberg` order kind and leaves an old
function un-updated:

```ocaml
type order = Live of live | Done of done_reason
           | Iceberg of { shown : int; hidden : int }   (* NEW *)

let status_label = function
  | Live l -> ...
  | Done Filled -> "filled"
  | Done Cancelled -> "cancelled"      (* Iceberg not handled *)
```

```
$ ocamlopt -c iceberg_refactor.ml
File "iceberg_refactor.ml", lines 14-17:
Warning 8 [partial-match]: this pattern-matching is not exhaustive.
  Here is an example of a case that is not matched: Iceberg _
```

In a 30-million-line monorepo, that warning at *every* affected match is what makes a
type-driven refactor safe. (Jane Street builds with warning 8 promoted to an error, so the build
fails until each site is handled.)

## The honest Rust comparison

Rust gives you the same guarantee — and is in fact *stricter* by default: a non-exhaustive
`match` is a hard error (`E0004`), not a warning. `iceberg_refactor.rs` adds the same variant:

```
$ rustc --edition 2021 --crate-type lib iceberg_refactor.rs
error[E0004]: non-exhaustive patterns: `&Order::Iceberg { .. }` not covered
  --> iceberg_refactor.rs:13:11
   |
13 |     match o {
   |           ^ pattern `&Order::Iceberg { .. }` not covered
```

So who wins? On *this* axis it's roughly a tie — both compilers find every site. Jane Street's
argument is the cumulative ergonomics: across a huge codebase, OCaml's inference, sum types,
functors and the absence of lifetime/borrow obligations on ordinary data make these refactors
cheaper to *write*, which (they argue) is what actually compounds at scale. That is a judgment
about productivity, not a benchmark — so we present it as such, and let the latency numbers in
the top-level README carry the quantitative half of the story.

## Reproduce

```
ocamlopt order_status.ml -o os && ./os        # prints live(6@100)
ocamlopt -c illegal_fail.ml                   # type error
ocamlopt -c iceberg_refactor.ml               # warning 8
rustc --edition 2021 --crate-type lib order_status.rs       # compiles
rustc --edition 2021 --crate-type lib iceberg_refactor.rs   # error E0004
```
