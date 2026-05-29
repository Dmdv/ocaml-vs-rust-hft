# OCaml vs Rust for low-latency trading

[![CI](https://github.com/Dmdv/ocaml-vs-rust-hft/actions/workflows/ci.yml/badge.svg)](https://github.com/Dmdv/ocaml-vs-rust-hft/actions/workflows/ci.yml)

A price-time-priority **limit-order-book matching engine** (the hot loop at the centre of a
trading system), built three times and run on the **same input bytes**:

| | language / mode | notes |
|---|---|---|
| **Rust** | stable 1.95, `Vec`-arena + `HashMap`, no GC | the no-GC baseline; the intrusive list costs lifetime/ownership boilerplate |
| **OCaml — idiomatic** | 5.4.1 + flambda, boxed records + `Hashtbl` | the natural OCaml style; one record allocated per resting order |
| **OCaml — zero-alloc** | OxCaml / flambda2, flat arrays + custom int-map | the same logic with the heap taken out of the hot path |

All three read the same 5,000,000-message stream and produce **byte-identical trades and final
book state**, checked against a committed golden hash. Because the outputs match, the benchmark
isolates the one thing that differs between them: how each lays out an order in memory. It is the
"why OCaml, not Rust?" question Jane Street has written about for years, in a form you can run.

> In short: for this workload the number that matters is the tail, not the average. The
> zero-allocation OCaml engine holds its worst-case latency level with Rust, and edges ahead at
> the far tail, while idiomatic OCaml pays for its garbage collector with a millisecond-scale
> pause. Rust keeps a roughly 3× lead on throughput. Trading some of that throughput for OCaml's
> expressiveness and safety is the bargain Jane Street has chosen.

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

## Reading the results

**1. The tail goes to the zero-alloc design.** Idiomatic OCaml allocates one record per resting
order. Over 5M messages that triggers 74 minor collections, and the slowest single message takes
**1.24 ms**, a GC pause about 28,000× the median. The zero-alloc engine never touches the heap on
the hot path, runs **zero** GC cycles, and its slowest message is **45 µs**, under Rust's 60 µs.
If the risk you care about is a collector pause landing mid-quote, taking the GC out of the hot
path buys far more than trimming nanoseconds off the median. This is the "zero-allocation style"
Jane Street writes about, and the reason OxCaml exists.

**2. Throughput and median latency still go to Rust (~3× and ~2×).** Some of that is a more mature
optimizer (LLVM against flambda2 in the OxCaml 5.2 preview); some is Rust's `hashbrown` `HashMap`,
with its SIMD probing, against a hand-written OCaml int-map. It matches what Jane Street's own
engineers say: *"we're fighting a fundamental disadvantage… anyone can write fast C++, but it
takes a real expert to write fast OCaml."* On a tight loop, OCaml does not pull level with Rust.

**3. Most of the zero-alloc work is plain OCaml; OxCaml makes it safe and readable.** In an
int-keyed book OCaml's ints are already unboxed, so the only allocations in the idiomatic version
were the boxed node record and the `Hashtbl`'s options and buckets. You can remove those in
ordinary OCaml, with a flat strided arena and a custom map; it is just tedious to write and easy
to get wrong. What OxCaml adds, per its docs, is (a) **unboxed record types**, which give the same
flat layout with record syntax instead of manual offset arithmetic, and (b) a **mode system** that
proves at compile time that a function never allocates and is free of data races. It turns a
hand-kept discipline into one the compiler enforces. (OxCaml's SIMD is x86-only, so it is unused
here on arm64.)

**4. Latency is only half the argument; expressiveness is the rest.** See
[`docs/expressiveness/`](docs/expressiveness/): modelling order status as a sum type turns "cancel
an already-filled order" into a *compile error*, and adding an `Iceberg` order kind makes the
compiler list every match that now needs updating. Rust does the same, and is stricter about it:
a non-exhaustive match is an error there, not a warning. The difference is how much ceremony each
demands across a large codebase, which is a judgment about day-to-day productivity rather than
something this benchmark measures.

## How it's built

- **One shared contract**, [`spec/protocol.md`](spec/protocol.md): a fixed 24-byte binary message
  format and the matching rules (price-time priority; trades print at the maker's price;
  add/cancel/replace/market).
- **One workload generator**, [`bench/gen_workload`](bench/gen_workload) (Rust, seeded), writes the
  byte stream every engine reads. The mix is ~60% add / 30% cancel / 5% replace / 5% market, with
  prices clustered around a mid that random-walks.
- **The same algorithm and data structures** in all three: an array price ladder for O(1)
  best-price access, an index-arena intrusive FIFO at each level for O(1) cancel, and a hash map
  from order id to slot. The only deliberate difference is how an order is represented (boxed
  records versus flat arrays) and the language itself.
- **A differential gate**: `scripts/run_all.sh` fails unless all three reproduce the committed
  golden `trades_hash` and `book_digest`. That check is what lets the latency numbers mean
  something: it shows the three are doing identical work.
- **Like-for-like measurement**: same input bytes; a warmup pass and median-of-N runs; full
  optimization on both sides (Rust `--release` with `lto=fat` and `codegen-units=1`, OCaml flambda
  `-O3`); array bounds checks left on in both languages; and per-message timing from the same
  `mach_absolute_time` clock (reached through a zero-alloc C stub on the OCaml side) so both are
  measured the same way.

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

- **A MacBook is not a production trading box.** No core isolation, no kernel bypass, and
  scheduler and thermal jitter throughout. Read these as relative numbers measured under identical
  conditions, not as absolute production latencies. A Linux host with `taskset` core-pinning would
  pull in every tail; [`docker/`](docker/) runs the same benchmark that way.
- **OxCaml is a 5.2 preview**, and flambda2 is a much younger backend than the LLVM behind Rust.
  Part of the throughput gap is toolchain maturity rather than anything about the language.
- **One symbol, one core, in memory** (no networking or persistence). That is deliberate: the
  target is the matching hot loop itself, not a whole exchange.
- **Allocation is counted differently per runtime**: `Gc.minor_words` in OCaml, a counting global
  allocator in Rust. Both methods are documented in the harness code.

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

For cleaner, core-pinned numbers on Linux (the whole toolchain in one image, the same benchmark
run under `taskset`), see [`docker/README.md`](docker/README.md):

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
