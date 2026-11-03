#!/usr/bin/env bash
# Native check of the bitwise not and of a register-bounded index (the VLA count), scripts/pathb-ssa-qbe.rb.
# The interpreter does not model `not`, so the expected values are hand-computed: f(n, i) = ~n + i, trapping unless
# 0 <= i < n (unsigned).
set -eu
cd "$(dirname "$0")/../../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ruby scripts/pathb-ssa-build -o "$tmp/nb.s" tests/pathb-ssa-qbe/not_bounds/nb.ir
cc tests/pathb-ssa-qbe/not_bounds/drv.c "$tmp/nb.s" -o "$tmp/prog"
got=$("$tmp/prog" | tr '\n' ' ')
want="-2 trap -5 trap trap "
if [ "$got" = "$want" ]; then
  echo "ok   not_bounds: $got"
else
  echo "FAIL not_bounds: got '$got', want '$want'"
  exit 1
fi

# The time-stamp read (rdtsc) as a value and as a discarded statement: the helper links and the counter is nonzero.
ruby scripts/pathb-ssa-build -o "$tmp/rd.s" tests/pathb-ssa-qbe/not_bounds/rd.ir
printf '#include <stdio.h>\nint g(int x);\nint main(void) { printf("%%d\\n", g(0)); return 0; }\n' > "$tmp/rd.c"
cc "$tmp/rd.c" "$tmp/rd.s" -o "$tmp/rdprog"
rdgot=$("$tmp/rdprog")
if [ "$rdgot" = "1" ]; then
  echo "ok   rdtsc: $rdgot"
else
  echo "FAIL rdtsc: got '$rdgot', want 1"
  exit 1
fi
