# OCaml vs Rust for low-latency trading

[![CI](https://github.com/Dmdv/ocaml-vs-rust-hft/actions/workflows/ci.yml/badge.svg)](https://github.com/Dmdv/ocaml-vs-rust-hft/actions/workflows/ci.yml)

A price-time-priority **limit-order-book matching engine** — the hot loop in a matching/execution
system — implemented three times and driven from the **same input bytes**:

| | language / mode | representation under test |
|---|---|---|
| **Rust** | stable 1.95, `Vec`-arena + `HashMap`, no GC | no-GC baseline; the intrusive free-list is expressed through arena indices to satisfy the borrow checker |
| **OCaml — idiomatic** | 5.4.1 + flambda, boxed records + `Hashtbl` | the natural OCaml encoding: one heap-boxed record per resting order, `Hashtbl` for id→order |
| **OCaml — zero-alloc** | OxCaml / flambda2, flat arrays + custom int-map | same algorithm, no heap traffic on the hot path: struct-of-fields in a strided `int array`, open-addressing int map |

All three consume the same 5,000,000-message stream and emit **byte-identical trades and final
book state**, verified against a committed golden hash (FNV-1a over the trade stream and over the
resting book). Identical output means the benchmark isolates exactly one variable — the in-memory
representation of an order — and holds the algorithm, data structures, and input constant. This is
the "why OCaml, not Rust?" question Jane Street has written about for years, reduced to something
you can build and measure.

> **Bottom line:** on this workload the figure that matters is tail latency, not the mean. The
> zero-allocation OCaml engine holds its tail level with Rust (and slightly lower at the extreme),
> while the idiomatic encoding's minor GC injects a stop-the-world pause three orders of magnitude
> above its median. Rust keeps a ~3× throughput lead — a more mature optimizer and a faster hash
> table, not a language-level law. Spending that throughput to buy OCaml's type system and lower
> defect rate is the trade Jane Street makes.

## Results (Apple Silicon, median of 5 runs, 5M messages → 3.12M trades)

![Per-message latency by percentile](bench/results/latency_tail.png)

**Latency per message (nanoseconds):**

| Engine | p50 | p90 | p99 | p99.9 | p99.99 | **max** |
|---|---:|---:|---:|---:|---:|---:|
| Rust | **41** | **83** | **208** | **417** | **1,334** | 59,500 |
| OCaml — idiomatic | 83 | 208 | 542 | 916 | 2,833 | **1,244,125** |
| OCaml — zero-alloc (OxCaml) | 84 | 167 | 334 | 542 | 1,708 | **44,875** |

**Throughput & allocation:**

| Engine | throughput | allocation on the hot path |
|---|---:|---|
| Rust | **29.2 M msg/s** | ~0 (13 allocations total over 5M msgs) |
| OCaml — idiomatic | 9.3 M msg/s | 3.8 minor words/op → **74 GC cycles** |
| OCaml — zero-alloc | 10.0 M msg/s | **0 words/op → 0 GC cycles** |

![Throughput](bench/results/throughput.png)

### How to read the percentiles

We time each message's `process` call and sort the samples. Every column is a percentile of that
latency distribution — i.e. "X% of messages were at least this fast":

- **p50 (median)** — half the messages finish faster, half slower. The cost of a *typical* message.
- **p90 / p99** — 90% / 99% finish at or under this; equivalently the slowest 1-in-10 and 1-in-100.
- **p99.9 / p99.99** — the slowest 1-in-1,000 and 1-in-10,000.
- **max** — the single worst message in the run.

For a matching engine the tail, not the mean, is the number you design against:

- **Tail events are frequent in absolute terms.** At a few million messages per run, p99.99 still
  describes hundreds of messages, and `max` is a real event that occurred. A venue doing millions
  of messages/second crosses its p99.9 thousands of times a second — the rare case is your steady
  state.
- **The slow message is usually the one that matters.** Latency spikes correlate with load bursts:
  the market just moved, every participant is reacting, the book is deepest. A strong median with a
  weak tail means you are slowest exactly when fills, cancels, and quotes are most contended.
- **The shape is a diagnosis.** The median reflects raw per-message compute; the gap from median to
  tail is jitter, and its causes are identifiable — allocation/GC, cache misses, branch
  mispredicts, scheduler preemption. A curve that stays flat from p50 to `max` is *predictable*; a
  knee at the high percentiles means something stalls intermittently. Here the idiomatic OCaml
  curve is flat until it jumps ~28,000× at `max` — a stop-the-world minor collection. The
  zero-alloc curve has no knee because it never collects. Rust and zero-alloc OCaml are flat;
  idiomatic OCaml is flat-then-cliff.

## Interpreting the results

**1. The tail goes to the zero-alloc engine.** *("The tail goes to X" is shorthand: of the three,
X wins on tail latency — the p99.9 / p99.99 / `max` columns above, the worst cases — which is a
separate question from who wins the median. The same "goes to X" phrasing is reused for the other
metrics below.)* The idiomatic encoding allocates one boxed record per resting order; over 5M
messages that drives 74 minor collections, and the worst single message is **1.24 ms** — ~28,000×
its own median, i.e. a stop-the-world minor GC caught in the timed region. The zero-alloc engine makes no hot-path allocations, triggers **zero** collections,
and tops out at **45 µs**, below Rust's 60 µs `max`. When the failure mode is a collector pause
landing between a quote and its fill, removing allocation from the hot path dominates median
nanoseconds. This is the "zero-allocation style" Jane Street documents, and the motivation for
OxCaml.

**2. Throughput and median latency still go to Rust (~3× and ~2×).** Two causes, both below the
language level: a more mature optimizer (LLVM vs flambda2 in the OxCaml 5.2 preview), and Rust's
`hashbrown` `HashMap` with SIMD probing vs a hand-written open-addressing int→int map on the OCaml
side. It matches what Jane Street's engineers say outright: *"we're fighting a fundamental
disadvantage… anyone can write fast C++, but it takes a real expert to write fast OCaml."* On a
tight loop, OCaml does not reach Rust.

**3. Most of the zero-alloc work is ordinary OCaml; OxCaml makes it machine-checked.** OCaml `int`
is unboxed, so in an int-keyed book the only idiomatic allocations are the boxed node record and
the `Hashtbl`'s `option` results and bucket cells. Both are removable in plain OCaml — a flat
strided `int array` arena plus a custom int→int map — at the cost of manual offset arithmetic and
no compiler check when you slip. OxCaml adds (a) **unboxed record types**, which recover that flat
layout with record syntax instead of hand-coded offsets, and (b) a **mode system** that proves at
compile time that a function allocates nothing and is data-race-free. It converts a
hand-maintained invariant into one the type checker enforces. (OxCaml's SIMD intrinsics are
x86-only, so they are unused here on arm64.)

**4. Latency is half the case; expressiveness is the other half.** See
[`docs/expressiveness/`](docs/expressiveness/): encoding order status as a sum type makes "cancel
an already-filled order" a *type error*, and adding an `Iceberg` constructor makes the compiler
enumerate every non-exhaustive `match` that now needs a case. Rust does the same and is stricter —
a non-exhaustive match is a hard error there, not a warning (`-w` vs `E0004`). The practical
difference is the ceremony each demands across a large codebase, which is a productivity argument,
not something this benchmark measures.

## How it's built

- **One shared contract**, [`spec/protocol.md`](spec/protocol.md): a fixed 24-byte little-endian
  message format and the matching rules (price-time priority; trades print at the resting/maker
  price; add/cancel/replace/market).
- **One workload generator**, [`bench/gen_workload`](bench/gen_workload) (Rust, seeded), writes the
  byte stream every engine reads. Mix ≈ 60% add / 30% cancel / 5% replace / 5% market, prices
  clustered (Gaussian) around a random-walking mid so a realistic fraction of orders cross.
- **Same algorithm and data structures** across all three: an `O(1)` array price ladder for the
  best bid/ask, an index-arena intrusive doubly-linked FIFO per level for `O(1)` cancel, and an
  id→slot map. The only deliberate differences are the order representation (boxed records vs flat
  arrays) and the language.
- **Equalised output path**: trades are appended to a preallocated in-engine buffer in all three —
  no per-trade allocation, and no dynamic dispatch (an earlier Rust version used a monomorphised
  generic sink, which OCaml can't match; it was removed so neither side gets a dispatch edge).
- **Differential gate**: `scripts/run_all.sh` fails unless all three reproduce the committed golden
  `trades_hash` and `book_digest`. That check is what makes the latency numbers comparable — it
  proves the three did identical work, bit for bit.
- **Like-for-like measurement**: same input bytes; warmup pass + median-of-N runs; full
  optimisation both sides (Rust `--release`, `lto=fat`, `codegen-units=1`, `target-cpu=native`;
  OCaml flambda `-O3`); array bounds checks left **on** in both languages; per-message timing from
  the same `mach_absolute_time` source (via a `[@@noalloc]` C stub on the OCaml side) so the clock
  is identical.

```
spec/        the shared protocol + matching spec + golden hash
bench/       gen_workload (Rust), analyze.py, committed charts
rust/        the Rust engine + harness + property tests
ocaml/idiomatic/   boxed-record engine (flambda)
ocaml/oxcaml/      zero-alloc engine (OxCaml / flambda2)
docs/        design, plan, and the expressiveness demo
scripts/run_all.sh build all, run, verify differential, chart
```

## Caveats

- **A laptop is not a production trading box.** No core isolation, no kernel bypass, SMT and
  frequency scaling and scheduler preemption all in play. Treat these as relative numbers under
  identical conditions, not absolute production latencies. Why this hardware can't be core-pinned
  at all, and how to pin properly on Linux, is its own section below.
- **OxCaml is a 5.2 preview**; flambda2 is a much younger backend than the LLVM behind Rust. Part
  of the throughput gap is toolchain maturity, not the language.
- **One symbol, one core, in memory** — no networking, no persistence. Deliberate: the target is
  the matching hot loop, not a full venue.
- **Allocation is measured per-runtime**: `Gc.minor_words` deltas in OCaml, a counting
  `GlobalAlloc` in Rust. Both methods are in the harness source.

## Core pinning

The headline run is on an Apple Silicon laptop — the development machine, not a trading box. That
is fine for what this benchmark claims: a *relative* comparison needs only identical conditions
across the three engines (same machine, same input bytes, same clock), which any single machine
provides. Absolute, production-grade latency is a different goal and wants a tuned Linux server —
which is what the Docker/Linux path below is for. OxCaml also runs natively on arm64 macOS (stack
allocation, modes and unboxed types all work; only its SIMD intrinsics are x86-only, and unused
here), so the zero-alloc engine needs no emulation.

These numbers are **not** core-pinned, and on this hardware they can't be:

- **macOS has never offered hard core-pinning** on any architecture: no `taskset`, no "run this
  thread on core N." It has the **Thread Affinity API** (`thread_policy_set` with
  `THREAD_AFFINITY_POLICY`), which sets *affinity tags* — a hint that threads sharing a tag be
  scheduled onto the same L2 cache (hence the same physical core) when possible. That is
  cache-locality grouping, not pinning, and not a guarantee.
- **On Apple Silicon (arm64) the affinity API is unavailable.** The kernel's
  `ml_get_max_affinity_sets()` is hardcoded to `0`, so `thread_policy_set(…, THREAD_AFFINITY_POLICY,
  …)` returns `KERN_NOT_SUPPORTED` (error 46). Apple's sanctioned alternative is **QoS classes**,
  which bias work toward performance vs efficiency cores but cannot pin a thread or stop migration
  and preemption.

For real pinning the repo provides a Linux path:

- `scripts/run_all.sh` honours `PIN_CPU=<n>` and wraps each harness in `taskset -c <n>` (a no-op
  where `taskset` is absent, i.e. macOS; active on Linux).
- Docker runs pinned: `docker run --cpuset-cpus 1,2 -e PIN_CPU=1 …`. On Docker Desktop for macOS
  this pins to a **VM vCPU** — it cuts migration jitter but is not real isolation. On bare-metal
  Linux, boot with `isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3`, run with `--cpuset-cpus 2,3 -e
  PIN_CPU=2`, and set the governor to `performance`; then the tail reflects the engine, not the
  scheduler.
- **CI runs unpinned on purpose**: shared GitHub runners expose no isolated core, so pinning there
  would add noise, not signal.

References:
[Affinity API release notes](https://developer.apple.com/library/archive/releasenotes/Performance/RN-AffinityAPI/) ·
[`thread_policy_set`](https://developer.apple.com/documentation/kernel/1418892-thread_policy_set) ·
[Apple forums — affinity on Apple Silicon](https://developer.apple.com/forums/thread/703361) ·
[Binding threads to cores on OSX](https://www.hybridkernel.com/2015/01/18/binding_threads_to_cores_osx.html)

## Reproduce

```bash
# OCaml: opam + two switches; Rust: stable 1.95; Python: matplotlib (see below)
opam switch create 5.4.1-flambda ocaml-variants.5.4.1+options ocaml-option-flambda
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam install dune core mtime
python3 -m venv bench/.venv && bench/.venv/bin/pip install matplotlib numpy

scripts/run_all.sh            # build all, run, verify differential, render charts
# or: scripts/run_all.sh 1000000 3   # smaller/faster
```

For core-pinned numbers on Linux (the whole toolchain in one image, the benchmark run under
`taskset`), see [`docker/README.md`](docker/README.md):

```bash
docker build -f docker/Dockerfile -t ocaml-vs-rust-hft:linux .   # ~30-45 min first build
docker run --rm --cpuset-cpus 1,2 -e PIN_CPU=1 ocaml-vs-rust-hft:linux
```

Per-engine tests: `cargo test --manifest-path rust/Cargo.toml`,
`dune test --root ocaml/idiomatic`, `dune test --root ocaml/oxcaml`.

## Sources (Jane Street's own words)

- Yaron Minsky, *OCaml for the Masses* (CACM, 2011) — readability as risk control.
- *Oxidizing OCaml: Locality* & *Introducing OxCaml* (blog.janestreet.com, 2025) — zero-alloc
  style, stack allocation, modes, unboxed types.
- *Performance Engineering on Hard Mode* (Signals & Threads) — where they concede the GC/boxiness
  disadvantage.
- *Building Tools for Traders* / *Safe at Any Speed* — the order-book and feed-handler workloads
  (sub-microsecond per message).
- [oxcaml.org](https://oxcaml.org) — modes, stack allocation, unboxed types.

_A demonstration project; the design and implementation plan are in `docs/plans/`._
