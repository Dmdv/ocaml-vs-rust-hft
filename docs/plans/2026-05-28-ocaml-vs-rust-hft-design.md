# OCaml vs Rust for Low-Latency Trading — Demo Design

**Date:** 2026-05-28
**Status:** Approved (brainstorming complete; auto mode)
**Author:** Claude + Dima

## Thesis

Demonstrate *why* Jane Street builds trading systems in OCaml and *why not* Rust — honestly,
with a head-to-head on a canonical HFT workload. The argument has two legs, and a credible
demo must carry both:

1. **Latency.** Idiomatic OCaml pays a GC/boxing tax (Jane Street openly calls this "a
   fundamental disadvantage" vs Rust). **OxCaml** — Jane Street's open compiler branch — closes
   the gap with stack allocation (`local_`), a mode system, and unboxed types, "pay-as-you-go":
   you opt into Rust-like control only on the hot path, not globally.
2. **Expressiveness / safety.** OCaml's type system enables "fearless refactoring" at scale and
   makes illegal states unrepresentable, with less ceremony than Rust's mandatory borrow checker.

**Honest framing (not "OCaml dominates"):** Rust has no GC, real ownership, and mechanical
sympathy by default; its types and exhaustiveness are also strong. The thesis is
*expressiveness-per-unit-ceremony* + *latency-you-opt-into*, validated by measurement.

### Key research anchors
- Minsky, *OCaml for the Masses* (CACM 2011): "readability as risk control."
- *Oxidizing OCaml: Locality* / *Introducing OxCaml* (blog.janestreet.com, 2025): zero-alloc style, `local_`, modes, unboxed types.
- *Performance Engineering on Hard Mode* (Signals & Threads): the candid GC/boxiness weakness.
- *Building Tools for Traders* (S&T) and *Safe at Any Speed* (feed handler, <750 ns/msg): canonical workloads.
- Proof point: OxCaml `httpz` parser — 0 heap words, 154 ns, 6.5M req/s.

## Scope (focused & deep)

One realistic core component — a **price-time-priority limit-order-book matching engine** —
implemented **three ways** against **byte-identical input**, with rigorous, fair benchmarks and
an expressiveness showcase. Not a full trading stack; a thin ITCH-style binary decoder is the
input adapter so the zero-alloc-parsing angle is represented without becoming the focus.

## Architecture & repo layout

```
ocaml-vs-rust-hft/                 (local: /Users/dima/ocaml; GitHub: private @ Dmdv)
  README.md            # the report: thesis, charts, honest caveats, reproduce steps
  docs/plans/          # this design + implementation plan
  spec/protocol.md     # binary message format + matching semantics — THE source of truth
  bench/
    gen_workload       # deterministic seeded generator -> orders.bin + golden_trades.csv
    analyze.py         # latencies.csv (x3) -> tail-latency CDF, throughput/alloc/GC tables
    results/           # committed charts + tables
  rust/    src/ (engine) benches/ (criterion) tests/ (proptest + differential)
  ocaml/   lib/ (idiomatic, Core) lib_ox/ (OxCaml zero-alloc) bin/ (harness) test/ (qcheck)
  scripts/run_all.sh   # build all, run, analyze, regenerate charts
```

Workload is generated **once** by a neutral tool and consumed identically by every engine, so we
can prove (a) they do equal work and (b) they produce identical results.

## Domain: the matching engine

Price-time priority (standard equity model). Message types (compact fixed-width binary,
ITCH-5.0-inspired, minimal): **Add** (limit: side/price/qty), **Cancel** (id), **Replace**
(id/new qty|price; price change loses time priority), **Market** (side/qty). Outputs: **trades**
(maker id, taker id, price, qty) + **acks**. Hot loop = "process one message → mutate book →
emit events."

Data structures (same algorithm across all three — we compare *representations*, not cleverness):
- **Price ladder**: array indexed by integer tick → O(1) best-price tracking (real-engine style);
  a sorted-map variant (`BTreeMap` / `Map`) included for comparison.
- **FIFO queue per level**: intrusive doubly-linked list → O(1) cancel.
- **Order id → node** map → O(1) cancel/replace.

## The three implementations

| Impl | Written as | Demonstrates |
|---|---|---|
| **Rust** (baseline) | structs + arena/freelist, `BTreeMap`/array ladder, no GC | mechanical sympathy; the ownership/lifetime *ceremony* the intrusive list costs |
| **Idiomatic OCaml** | `Core` containers, boxed records, expressive | honest GC tax: per-order boxing/alloc → minor-GC pauses on the tail |
| **OxCaml** | same logic; unboxed records `#{}`, `local_` stack alloc, `let mutable`, unboxed int prices | the rebuttal: 0 heap words on the hot path → Rust-class tail latency, still readable |

Three-way is essential: idiomatic OCaml alone *loses* to Rust on tail latency (the honest
weakness); OxCaml is the rebuttal and the "opt-in" story.

## Expressiveness leg (committed artifacts)

1. **Illegal states unrepresentable.** Order lifecycle as a variant/GADT so a `Filled` order has
   no remaining-qty field and cannot be passed to `cancel` — the bug doesn't compile. Rust
   typestate shown beside it; honest that Rust *can* do this, OCaml does it with less ceremony.
2. **"Ultimate refactoring tool" demo.** Add an **iceberg/hidden-quantity** order type; capture
   the compiler enumerating every non-exhaustive match that must change. Artifact = before/after
   diff + compiler output. Shown in both languages.

## Benchmark methodology

- **Workload**: deterministic seeded generator, ~5M messages, mix ≈ 60% add / 30% cancel / 5%
  replace / 5% market; prices clustered near mid (Gaussian); realistic high cancel rate. Generated
  by `run_all.sh` with a fixed seed (reproducible); golden output committed.
- **Metrics**: throughput (steady-state msg/s); per-op latency → HDR histogram → p50/p90/p99/
  p99.9/p99.99/max; allocations/op (OCaml `minor_words`/`major_words`; Rust counting global
  allocator or `dhat`); OCaml GC pause behavior (`Gc.quick_stat`).
- **Headline chart**: three-way tail-latency CDF (log-y).
- **Fairness**: identical input bytes; warmup; median of N runs; max opt flags both sides (OCaml
  Flambda + cross-module inlining; Rust `--release`, `lto="fat"`, `codegen-units=1`,
  `target-cpu=native`); one neutral per-language harness emitting the same `latencies.csv` schema.
  Core pinning via `taskset` on Linux (note: limited on macOS).
- **Honesty**: macOS/Apple Silicon is not a production HFT environment (no core isolation/kernel
  bypass); numbers are *relative under identical conditions*, not absolute production latency.
  Optional Linux/Docker path provided. SIMD not used (OxCaml SIMD is x86-only; we're on arm64).

## Correctness / testing

- **Differential testing**: all three engines must emit byte-identical golden output on the
  workload → proves equal work (fairness) + correctness.
- **Property tests** (`proptest` / `qcheck`): book never crosses (best bid < best ask);
  total quantity conserved; price-time priority respected; cancel removes exactly one order.
- **Unit tests**: partial fills, self-trade, empty book, price improvement, replace semantics.

## Toolchain & platform

- **OCaml** via opam: switch `5.4.0+flambda` (idiomatic) + switch `5.2.0+ox` (OxCaml, from
  `oxcaml/opam-repository`). `dune`. Libs: `core`, `bechamel`/`core_bench`, `qcheck`. Confirmed:
  OxCaml stack-alloc/modes/unboxed work on arm64 macOS.
- **Rust** stable (1.95.x): `criterion`, `hdrhistogram`, `proptest`, `rand`.
- **Analysis**: Python 3 + `matplotlib`.
- **Latest versions** (2026): OCaml 5.4.1; OxCaml on 5.2; Rust 1.95.0.

## Deliverable: the README/report

Thesis → what a matching engine is → latency results (headline CDF + throughput/alloc/GC tables)
→ expressiveness leg (illegal-states snippets + refactoring demo with compiler output) → honest
caveats (platform; "expert to write fast OCaml"; where Rust wins; OxCaml is a branch, not
upstream) → reproduce instructions.

## Risks / open questions

- OxCaml switch build time/breakage on arm64 macOS — verify early; fall back to documenting if a
  specific feature is unavailable.
- Exact OxCaml unboxed-record syntax may need adjustment to the installed version's docs.
- Workload realism — calibrate the mix against published market microstructure stylized facts.
- Keep the repo lean: generate the multi-MB workload at runtime (fixed seed), commit only the
  generator + a checksum + a small sample.

## Out of scope

Networking, persistence, multiple symbols/threads (single-symbol single-core hot loop is the JS
canonical case), full ITCH 5.0 message set, kernel-bypass/FPGA.
