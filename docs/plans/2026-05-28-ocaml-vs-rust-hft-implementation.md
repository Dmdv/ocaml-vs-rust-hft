# OCaml-vs-Rust HFT Demo — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task. Follow TDD: failing test → run → implement → pass → commit.

**Goal:** Build a price-time-priority limit-order-book matching engine three ways (Rust, idiomatic OCaml, OxCaml zero-alloc) over byte-identical input, with fair latency/throughput/allocation benchmarks and a type-expressiveness showcase, to demonstrate honestly why Jane Street chooses OCaml — and where Rust still wins.

**Architecture:** One neutral tool generates a deterministic binary order stream. Each engine decodes the same bytes, runs the same matching algorithm (compared by *representation*, not cleverness), emits trades + per-op latencies. A reference output (committed golden) plus property tests guarantee the three engines do identical work, so the benchmark is fair. A Python script aggregates the three `latencies.csv` into a tail-latency CDF and tables.

**Tech Stack:** OCaml 5.4.0+flambda + 5.2.0+ox (OxCaml), dune, core, qcheck, bechamel; Rust 1.95 (criterion, hdrhistogram, proptest, rand); Python3 + matplotlib. macOS arm64.

**Shared contract (pin this down first — `spec/protocol.md`):**
- Wire: fixed **24-byte little-endian** records. `[u8 type][u8 side][u16 pad][u32 order_id][u32 price_ticks][u32 qty][u32 new_price][u32 new_qty]`. type: 0=Add,1=Cancel,2=Replace,3=Market. side: 0=Bid,1=Ask.
- Matching (price-time priority): incoming aggressor matches resting opposite side FIFO while crossing; **trade price = resting (maker) price**; remainder of a limit order rests with arrival-time priority; market-order remainder is discarded. Cancel removes a resting order (no-op if absent). Replace: qty-decrease keeps time priority; price-change or qty-increase loses priority (cancel + re-add at back).
- Engine output (for differential testing): trade stream `seq,maker_id,taker_id,price,qty,aggressor_side` + a final **book digest** (FNV-1a over sorted resting (id,side,price,qty)).
- Harness output: `latencies.csv` = one `nanos` per processed message (after warmup), plus a summary line `THROUGHPUT msgs=<n> elapsed_ns=<t>` and `ALLOC minor_words=<w> major_words=<w>` (engine-specific).

---

## Phase 0 — Toolchain & scaffolding

### Task 0.1: Create OCaml switches
**Steps:**
1. Confirm `opam init` done (bg). Run: `opam --version` (expect 2.5.1).
2. Idiomatic switch: `opam switch create 5.4.0-flambda ocaml-variants.5.4.0+options ocaml-option-flambda -y`. If the variant name fails, fall back to `opam switch create 5.4.0-flambda 5.4.0 && opam install -y ocaml-option-flambda` or use 5.4.1. Verify: `opam exec --switch 5.4.0-flambda -- ocaml -config | grep flambda` → `flambda: true`.
3. Install libs on idiomatic switch: `opam install -y --switch 5.4.0-flambda dune core core_bench bechamel qcheck`.
4. OxCaml switch: `opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default -y` (needs autoconf — installed). Verify: `opam exec --switch 5.2.0+ox -- ocaml -version`.
5. Install on OxCaml switch: `opam install -y --switch 5.2.0+ox dune`.
6. **Smoke test OxCaml features** (critical, do early): compile a tiny file using `local_`, `let mutable`, and an unboxed record `#{ ... }`; confirm it builds on arm64. If a feature is unavailable, note it in README caveats and degrade gracefully.
7. Commit: `chore: ocaml toolchain (flambda + oxcaml switches)`. (Switches live in ~/.opam, not the repo; this commit is just any scaffolding/notes.)

### Task 0.2: Verify Rust toolchain
1. `rustup update stable && rustc --version` (expect 1.95.x). If old, `rustup update`.
2. Note: criterion/hdrhistogram/proptest added per-crate in Phase 2.

### Task 0.3: Repo skeleton + GitHub repo
1. Create dirs: `spec/ bench/results/ rust/ ocaml/lib ocaml/lib_ox ocaml/bin ocaml/test scripts/`.
2. Write top-level `README.md` stub (title + "WIP").
3. Create private GitHub repo on **Dmdv**: `gh repo create Dmdv/ocaml-vs-rust-hft --private --source=. --remote=origin` (do NOT push until skeleton builds; confirm `gh auth status` first).
4. Commit: `chore: repo skeleton`.

---

## Phase 1 — Shared spec & neutral workload generator

### Task 1.1: Write `spec/protocol.md`
Document the wire format + matching semantics above in full. Commit.

### Task 1.2: Workload generator (Rust, neutral) — `bench/gen_workload/`
**Files:** Create `bench/gen_workload/Cargo.toml`, `src/main.rs`.
**Behavior:** seeded (`StdRng::seed_from_u64(42)`), N=5_000_000 default (CLI arg). Mix ≈ 60% Add / 30% Cancel / 5% Replace / 5% Market. Prices ~ integer ticks Gaussian around a mid that random-walks; qty ~ lognormal-ish small ints. Track live order ids so Cancel/Replace target real ids. Write fixed 24-byte LE records to `bench/orders.bin`.
**TDD:** test that output file size == N*24; test decoder round-trips a known record; test the id-tracking never cancels a non-existent id more than a small configured rate.
**Commit:** `feat: deterministic workload generator`.

---

## Phase 2 — Rust engine (baseline + reference for golden)

### Task 2.1: Crate + types
**Files:** `rust/Cargo.toml` (deps: rand, hdrhistogram, clap; dev: criterion, proptest). `rust/src/lib.rs`, `rust/src/book.rs`.
Types: `Side{Bid,Ask}`, `Order{id:u32,price:u32,qty:u32}`, `Trade{maker,taker,price,qty,aggressor}`. Book uses an **index-arena** (`Vec<OrderNode>` + freelist) for orders (idiomatic safe-Rust intrusive list via indices), a price→level map (start with `BTreeMap<u32, Level>`; add array-ladder variant later), `HashMap<u32, usize>` id→node.

### Task 2.2: Matching — TDD loop (one behavior per cycle)
For each rule, write failing test → implement → pass → commit:
- add resting order (no cross) updates best
- crossing limit generates trade at maker price, partial fill
- full sweep across multiple levels
- market order, market with insufficient liquidity (remainder discarded)
- cancel present / absent
- replace qty-down keeps priority; price-change loses priority
- book digest stable
Run: `cargo test -p <crate> -- --nocapture`.

### Task 2.3: Binary decoder + harness `rust/src/bin/harness.rs`
Read `orders.bin` via mmap or buffered read; decode 24-byte records (zero-copy); for each, time `engine.process(msg)` with `Instant::now()` (or `rdtsc`-style via `std::time`), record nanos into a `Vec<u64>` (preallocated, no per-op alloc), write `latencies.csv` after the run (warmup first 10%). Emit trades to `trades.csv`, print book digest. Add a counting global allocator (`#[global_allocator]`) to report total allocations.
**Commit:** `feat: rust engine + harness`.

### Task 2.4: Property tests (`proptest`) + criterion bench
Properties: book never crosses; qty conserved (sum traded + resting == sum added); cancel removes ≤1; price-time priority. `rust/benches/match.rs` with criterion over a fixed in-memory stream. Run `cargo bench`.
**Commit:** `test: rust property tests + criterion`.

### Task 2.5: Generate committed golden
Run harness on `orders.bin`; save `spec/golden_trades.csv` (or a hash) + `spec/golden_digest.txt`. This is the reference all engines must match. **Commit.**

---

## Phase 3 — Idiomatic OCaml engine

> OCaml notes for a Rust dev: modules ≈ mod+trait; `type t = { ... }` records are heap-boxed by default; `Map.Make` ≈ `BTreeMap`; variants ≈ enums; `option` ≈ `Option`. We deliberately write *clean, allocating* code here.

### Task 3.1: dune project + types — `ocaml/lib/`
`ocaml/dune-project` (lang dune 3.x), `ocaml/lib/dune` (libraries core; flambda). `book.ml`/`book.mli`: `Side.t`, `order` record, `trade` record, book with `Map.M(Int).t` price ladder + `Hashtbl` id→order + per-level `Queue`/`Doubly_linked` (Core) for FIFO.

### Task 3.2: Matching — TDD (mirror Task 2.2 cases exactly)
Use `qcheck`/inline expect tests. Each behavior: failing test → implement → pass → commit. Run: `dune test`.

### Task 3.3: Decoder + harness — `ocaml/bin/harness.ml`
Read `orders.bin` (`In_channel`/`Bigstring`); decode via `Bytes`/`Bigstringaf`-style offset reads; time each `process` with `Mtime_clock.now`/`Time_now`; record into a preallocated `int array`; write `latencies.csv`; capture `Gc.quick_stat` minor/major words before/after. Emit trades + digest.
**Commit:** `feat: idiomatic ocaml engine + harness`.

### Task 3.4: Differential test vs golden + qcheck properties
Test: running on `orders.bin` reproduces `spec/golden_trades.csv` + `golden_digest.txt` exactly. Same properties as 2.4 via qcheck. `dune test`.
**Commit:** `test: ocaml differential + property tests`.

### Task 3.5: bechamel micro-bench `ocaml/bin/bench.ml`. **Commit.**

---

## Phase 4 — OxCaml zero-alloc engine

> Goal: identical algorithm, **0 minor_words on the hot path**. Techniques: unboxed records `#{ ... }`, unboxed ints (`int32#`/`int#`), `local_` stack allocation for transient values, `let mutable`, flat arrays (struct-of-arrays for the ladder). Verify exact syntax against installed OxCaml docs (Task 0.1 smoke test).

### Task 4.1: `ocaml/lib_ox/` dune (switch 5.2.0+ox), types as unboxed/flat.
### Task 4.2: Matching — reuse Task 3 tests (copy), make them pass with the unboxed representation. TDD.
### Task 4.3: Harness — assert **`minor_words` delta == 0** over the timed region (the headline claim). Fail the test if it allocates on the hot path.
### Task 4.4: Differential test vs golden (must match byte-for-byte) + properties.
**Commit per task.** Final: `feat: oxcaml zero-alloc engine (0 hot-path allocations)`.

---

## Phase 5 — Expressiveness artifacts

### Task 5.1: Illegal-states-unrepresentable — `ocaml/lib/order_state.ml` + `rust/src/order_state.rs`
GADT/variant so a `Filled` order has no remaining-qty and can't be `cancel`-ed (won't compile). A `_fail/` example file (excluded from build) showing the compile error. Rust typestate equivalent beside it. Honest README note: Rust can do this too; OCaml uses less ceremony.
**Commit.**

### Task 5.2: Refactoring demo — add an `Iceberg` (hidden-qty) order type
On a branch/scripted diff: add the variant, run `dune build`, capture the non-exhaustive-match warnings enumerating every site to fix; do the same in Rust (`cargo build` exhaustiveness errors). Save transcripts to `docs/refactor-demo/`.
**Commit:** `docs: refactoring demo (iceberg order)`.

---

## Phase 6 — Analysis & report

### Task 6.1: `bench/analyze.py`
Read the three `latencies.csv`; compute p50/p90/p99/p99.9/p99.99/max + throughput; render: (a) **tail-latency CDF** (log-y) overlay, (b) percentile bar chart, (c) throughput bar, (d) allocations/GC table → `bench/results/*.png` + `summary.md`. Use matplotlib; no seaborn.

### Task 6.2: `scripts/run_all.sh`
`set -euo pipefail`. Build gen + all engines (correct switches), regenerate `orders.bin`, run each harness (median of N=5, with warmup), run analyze.py, refresh `bench/results/`. Pin core via `taskset` if Linux.
**Commit:** `feat: analysis + run_all orchestrator`.

### Task 6.3: `README.md` — the report
Thesis → what a matching engine is → results (embed charts) → expressiveness (snippets + refactor transcript) → **honest caveats** (macOS not production HFT; "expert to write fast OCaml"; where Rust wins; OxCaml is a branch) → reproduce steps. Cite research sources.
**Commit:** `docs: README report with results`.

---

## Phase 7 — Publish
Push all to `Dmdv/ocaml-vs-rust-hft` (private). Verify CI-free build instructions work from clean clone (document, optionally a Linux Dockerfile for controlled numbers).
**Commit + push.**

---

## Risks / verify-early
- **OxCaml syntax/feature availability on arm64 macOS** — Task 0.1 smoke test is the gate; degrade gracefully + document if a feature is x86-only (SIMD definitely is — not used).
- **Switch build time** — flambda + oxcaml compiles are long; run in background.
- **Fair timing on macOS** — no core isolation; report relative numbers + offer Linux/Docker path.
- **Allocation measurement parity** — OCaml via `Gc`, Rust via counting allocator; document method.
