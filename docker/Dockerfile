# Reproducible Linux image for the OCaml-vs-Rust order-book benchmark.
#
# Provides a glibc Linux environment (required by OxCaml — musl/Alpine is unsupported) with all
# three toolchains, so the benchmark can run with `taskset` core-pinning for cleaner tail numbers
# than bare macOS. Builds natively on arm64 or x86-64; force a platform with
#   docker build --platform linux/amd64 ...
#
# NOTE: the first build compiles two OCaml compilers (incl. the OxCaml branch) + a Rust toolchain,
# so expect ~30-45 minutes. Subsequent runs are instant.
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    OPAMROOT=/root/.opam \
    OPAMYES=1 \
    PATH=/root/.cargo/bin:/usr/local/bin:/usr/bin:/bin

# System deps: opam/OCaml build, OxCaml (autoconf), gmp, rust build, python charts, taskset.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git curl ca-certificates m4 pkg-config unzip rsync \
        libgmp-dev autoconf \
        opam \
        python3 python3-venv python3-pip \
        util-linux procps \
    && rm -rf /var/lib/apt/lists/*

# opam: no sandbox inside a container.
RUN opam init --bare --disable-sandboxing -y

# Idiomatic OCaml switch (flambda) + its libs.
RUN opam switch create 5.4.1-flambda --packages=ocaml-variants.5.4.1+options,ocaml-option-flambda \
    && opam install -y --switch 5.4.1-flambda dune core mtime \
    && opam clean -a -y

# OxCaml switch (zero-alloc engine) from the OxCaml opam repository.
RUN opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default \
    && opam install -y --switch 5.2.0+ox dune \
    && opam clean -a -y

# Rust stable.
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile minimal \
    && rustc --version

WORKDIR /work
COPY . /work

# Python venv for charts, then pre-build everything so `docker run` is fast.
RUN python3 -m venv bench/.venv \
    && bench/.venv/bin/pip install --quiet --upgrade pip matplotlib numpy \
    && cargo build --release --manifest-path bench/gen_workload/Cargo.toml \
    && cargo build --release --manifest-path rust/Cargo.toml \
    && opam exec --switch 5.4.1-flambda -- dune build --root ocaml/idiomatic \
    && opam exec --switch 5.2.0+ox -- dune build --root ocaml/oxcaml

# Pin harnesses to CPU 1 by default (override with -e PIN_CPU=N, and constrain the container with
# --cpuset-cpus on a real host). Prints the summary table to stdout; mount a volume over
# /work/bench/results to extract the charts.
ENV PIN_CPU=1
CMD ["bash", "scripts/run_all.sh"]
