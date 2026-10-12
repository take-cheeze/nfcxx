#!/usr/bin/env bash
# Times the programs of tests/ast/bench with the tier off and on (docs/notes/ast.md, "Speed"). Not run by CI: the numbers are
# indicative, nothing asserts on them. The output of every run is compared with the tier-off output.
#   tests/ast/bench_tier.sh [PROGRAM...]       (default: every program)    NFCXX_BACKEND=gcc|qbe  (default: both)
# Per program and back end, in seconds of wall time: the interpreter alone (best of three), the tier with an empty cache (one run: the
# time the driver needs is in the figure), and the tier with the cache warm (best of three: a shared object is loaded, as on any run
# of a program after the first). The tier compiles each function at its first call here (NFCAST_TIER_THRESHOLD=1).
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
progs=("$@"); [ ${#progs[@]} -gt 0 ] || progs=(tests/ast/bench/*.lua)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
srcs=(lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp lib/ast/nfcast_parse.cpp lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp lib/ast/nfcast_tier.cpp tests/ast/driver.cpp)
# t SECONDS-VAR COMMAND...: runs the command once, its output to $tmp/out, and sets the variable to the wall time
t() { local var=$1; shift; local s=$(date +%s.%N); "$@" > "$tmp/out" 2>/dev/null; local e=$(date +%s.%N); printf -v "$var" '%.2f' "$(echo "$e - $s" | bc)"; }
# best VAR COMMAND...: the least of three runs
best() { local var=$1; shift; local b=; for _ in 1 2 3; do t x "$@"; if [ -z "$b" ] || [ "$(echo "$x < $b" | bc)" = 1 ]; then b=$x; fi; done; printf -v "$var" '%s' "$b"; }
export NFCXX="$PWD/nfcxx"
for be in $backends; do
  NFCXX_BACKEND=$be ./nfcxx -O2 -I lib/ast "${srcs[@]}" -o "$tmp/driver-$be" || exit 1
  echo "back end $be: seconds (interpreter | tier, cold cache | tier, warm cache)"
  for p in "${progs[@]}"; do
    name=$(basename "$p" .lua)
    best off env NFCAST_TIER=0 "$tmp/driver-$be" "$p"; cp "$tmp/out" "$tmp/ref"
    rm -rf "$tmp/cache"
    t cold env NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1 NFCAST_TIER_CACHE="$tmp/cache" NFCXX_BACKEND=$be "$tmp/driver-$be" "$p"; cmp -s "$tmp/out" "$tmp/ref" || echo "DIFFERENT OUTPUT (cold)"
    best warm env NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1 NFCAST_TIER_CACHE="$tmp/cache" NFCXX_BACKEND=$be "$tmp/driver-$be" "$p"; cmp -s "$tmp/out" "$tmp/ref" || echo "DIFFERENT OUTPUT (warm)"
    printf '  %-10s %6s | %6s | %6s\n' "$name" "$off" "$cold" "$warm"
  done
done
