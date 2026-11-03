#!/usr/bin/env bash
# Native check of a variadic definition: vastart and vaarg in the emitted code, called from C with C variadic arguments.
set -euo pipefail
cd "$(dirname "$0")/../../.."
d=$(mktemp -d)
trap "rm -rf $d" EXIT
ruby scripts/pathb-ssa-build -o "$d/sum.s" tests/pathb-ssa-qbe/vararg/sum.ir
cc tests/pathb-ssa-qbe/vararg/drv.c "$d/sum.s" -o "$d/prog"
out=$("$d/prog")
if [ "$out" = "60 0 15" ]; then echo "ok   vararg: $out"; else echo "FAIL vararg: $out"; exit 1; fi
