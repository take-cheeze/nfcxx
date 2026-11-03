#!/usr/bin/env bash
# Native check of alloca (a 16-byte-aligned dynamic stack block), of a volatile load and store (helper calls) in the
# emitted code, and of the driver's refusal path: the module emits, and the output runs from C.
set -euo pipefail
cd "$(dirname "$0")/../../.."
d=$(mktemp -d)
trap "rm -rf $d" EXIT
ruby scripts/pathb-ssa-build -o "$d/a.s" tests/pathb-ssa-qbe/refusals4/alloca_volatile.ir
cc tests/pathb-ssa-qbe/refusals4/drv.c "$d/a.s" -o "$d/prog"
out=$("$d/prog")
if [ "$out" = "7 7 7" ]; then echo "ok   alloca/volatile: $out"; else echo "FAIL alloca/volatile: $out"; exit 1; fi
