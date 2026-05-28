# Linux / Docker path — cleaner, core-pinned numbers

The top-level results are measured on macOS, which has no core isolation and noticeable
scheduler/thermal jitter (it inflates every tail). This image runs the *exact same* benchmark on
a glibc Linux environment with `taskset` core-pinning, which tightens the tails and — on a real
Linux host — is reproducible production-grade methodology.

(glibc matters: OxCaml does **not** support musl/Alpine, so the base image is Debian.)

## Build

```bash
# from the repo root. First build is ~30-45 min (it compiles two OCaml compilers incl. OxCaml,
# plus a Rust toolchain). Builds natively for your arch (arm64 here).
docker build -f docker/Dockerfile -t ocaml-vs-rust-hft:linux .

# force x86-64 instead (emulated on Apple Silicon, slow):
# docker build --platform linux/amd64 -f docker/Dockerfile -t ocaml-vs-rust-hft:linux-amd64 .
```

## Run

```bash
# Prints the differential check + the latency/throughput summary table to stdout.
docker run --rm ocaml-vs-rust-hft:linux

# Pin the container to dedicated cores and pick which one to measure on:
docker run --rm --cpuset-cpus 1,2 -e PIN_CPU=1 ocaml-vs-rust-hft:linux

# Extract the charts (latency_tail.png, throughput.png, summary.md) to ./docker-results:
docker run --rm -v "$PWD/docker-results:/work/bench/results" ocaml-vs-rust-hft:linux

# Smaller/faster sanity run (1M messages, 3 runs):
docker run --rm ocaml-vs-rust-hft:linux bash scripts/run_all.sh 1000000 3
```

## How clean are the numbers, really?

- **On Docker Desktop / macOS:** the container runs inside a LinuxKit VM, so `taskset` pins to a
  VM vCPU, not a physical core. It still reduces migration jitter and gives a real Linux GC/
  allocator, but it is **not** isolated. Treat it as "better than bare macOS", not authoritative.
- **On a bare-metal Linux host:** for production-grade tails, boot with `isolcpus=2,3
  nohz_full=2,3 rcu_nocbs=2,3`, run with `--cpuset-cpus 2,3 -e PIN_CPU=2`, and disable turbo /
  pin the governor to `performance`. Then the per-message tail reflects the engine, not the OS.

The point of this image is that the methodology is portable: the same `scripts/run_all.sh`
(workload seed, differential gate, median-of-N, identical compiler flags) runs unchanged, so
results from a laptop and a tuned server are directly comparable.
