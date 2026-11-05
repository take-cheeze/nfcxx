#!/usr/bin/env bash
# Compares our e-graph pass (scripts/pathb-egraph.rb) with egg 0.11 on the same random straight-line programs:
# the time of each, the size of the extracted programs, and whether each computes what the original computes.
# Needs cargo (the egg crate is fetched once). Usage: tests/pathb-egraph/egg/run.sh [OPS] [PROGRAMS] [SEED]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ops="${1:-50}"; progs="${2:-20}"; seed="${3:-7}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cargo build --release --manifest-path "$here/Cargo.toml" --target-dir "$tmp/target" -q
ruby "$here/gen.rb" "$progs" "$ops" "$seed" "$tmp/p"
"$tmp/target/release/eggbench" "$tmp/p.prog" "$tmp/egg.txt"
ruby "$here/compare.rb" "$tmp/p.ssa" "$tmp/egg.txt"
