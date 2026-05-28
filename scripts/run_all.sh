#!/usr/bin/env bash
# Build all engines, regenerate the workload, run each engine, verify the differential
# (every engine must reproduce the golden), and produce charts + a summary table.
#
# Usage: scripts/run_all.sh [N_MESSAGES] [RUNS_PER_ENGINE]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N="${1:-5000000}"
RUNS="${2:-5}"
FLAMBDA_SW="5.4.1-flambda"
OX_SW="5.2.0+ox"

echo "== building =="
cargo build --release --manifest-path bench/gen_workload/Cargo.toml
cargo build --release --manifest-path rust/Cargo.toml
opam exec --switch "$FLAMBDA_SW" -- dune build --root ocaml/idiomatic
opam exec --switch "$OX_SW" -- dune build --root ocaml/oxcaml

RUST_H="rust/target/release/harness"
IDIO_H="ocaml/idiomatic/_build/default/bin/harness.exe"
OX_H="ocaml/oxcaml/_build/default/bin/harness.exe"

echo "== generating workload (N=$N seed=42) =="
cargo run -q --release --manifest-path bench/gen_workload/Cargo.toml -- --count "$N" --seed 42 --out bench/orders.bin

TMP_ERR="$(mktemp)"
TMP_MPS="$(mktemp)"
trap 'rm -f "$TMP_ERR" "$TMP_MPS"' EXIT

run_engine() { # label dir harness_path
  label="$1"
  dir="$2"
  harness="$3"
  out="bench/results/$dir"
  mkdir -p "$out"
  : > "$TMP_MPS"
  i=0
  while [ "$i" -lt "$RUNS" ]; do
    "$harness" bench/orders.bin "$out" 2>"$TMP_ERR" 1>/dev/null || true
    grep -oE '[0-9.]+ M msg/s' "$TMP_ERR" | grep -oE '^[0-9.]+' >> "$TMP_MPS" || true
    i=$((i + 1))
  done
  cp "$TMP_ERR" "$out/summary.txt"
  median="$(sort -n "$TMP_MPS" | awk '{a[NR]=$0} END{print a[int((NR+1)/2)]}')"
  echo "MEDIAN_MPS=$median" >> "$out/summary.txt"
  echo "  $label: median ${median} M msg/s"
}

echo "== running engines ($RUNS runs each) =="
run_engine "Rust" rust "$RUST_H"
run_engine "OCaml idiomatic" ocaml_idiomatic "$IDIO_H"
run_engine "OCaml zero-alloc (OxCaml)" ocaml_oxcaml "$OX_H"

echo "== verifying differential (every engine must match the golden) =="
gold_hash="$(grep trades_hash spec/golden.txt | cut -d= -f2)"
gold_dig="$(grep book_digest spec/golden.txt | cut -d= -f2)"
fail=0
for dir in rust ocaml_idiomatic ocaml_oxcaml; do
  h="$(grep trades_hash "bench/results/$dir/digest.txt" | cut -d= -f2)"
  d="$(grep book_digest "bench/results/$dir/digest.txt" | cut -d= -f2)"
  if [ "$h" = "$gold_hash" ] && [ "$d" = "$gold_dig" ]; then
    echo "  OK   $dir"
  else
    echo "  FAIL $dir (trades_hash=$h book_digest=$d)"
    fail=1
  fi
done
[ "$fail" = 0 ] || {
  echo "DIFFERENTIAL FAILED — engines disagree"
  exit 1
}

echo "== analyzing =="
bench/.venv/bin/python bench/analyze.py
