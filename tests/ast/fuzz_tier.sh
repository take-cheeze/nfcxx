#!/usr/bin/env bash
# Differential fuzzing of the tier (docs/notes/ast.md, "Tiering") against a real Lua 5.4: random numeric kernels
# (fuzz/gen_kernel.py), called with random and sometimes wrongly typed arguments through pcall, run by the reference and by nfcast
# with every function compiled at its first call; the output, error messages included, must be equal. A mismatch is classified by
# running nfcast with the tier off: if that differs from the reference too, the engine and not the tier is at fault. Not part of CI
# (the programs in tests/ast/cases are; each seed compiles up to a few dozen functions, a few seconds each time on a cold cache).
#   tests/ast/fuzz_tier.sh [SEEDS [FUNCTIONS [FIRST_SEED]]]     (default: 30 seeds of 10 functions from seed 1)
#   LUA=/path/to/lua                 the reference (default: built from build/poly-lua/src like regen.sh does)
#   NFCXX_BACKEND=gcc|qbe            back end that builds the driver (default gcc)
#   NFCAST_TIER_CACHE=dir            the tier's cache (default: the library's)
cd "$(dirname "$0")/../.."
seeds=${1:-30}; nf=${2:-10}; first=${3:-1}
lua=${LUA:-}
if [ -z "$lua" ]; then
  [ -d build/poly-lua/src ] || { echo "fuzz_tier: no Lua source; run scripts/setup-poly-lua.sh, or pass LUA=/path/to/lua" >&2; exit 1; }
  mkdir -p build/ast-ref; lua=build/ast-ref/lua
  [ -x "$lua" ] || (cd build/poly-lua/src && cc -O2 -DLUA_USE_LINUX -o ../../ast-ref/lua $(ls l*.c | grep -v -E '^(luac|onelua|ltests)\.c$') -lm -ldl) || exit 1
fi
be=${NFCXX_BACKEND:-gcc}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
NFCXX_BACKEND=$be ./nfcxx -O2 -I lib/ast tests/ast/driver.cpp lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp lib/ast/nfcast_parse.cpp \
  lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp lib/ast/nfcast_tier.cpp -o "$tmp/driver" || exit 1
norm() { sed -E 's/0x[0-9a-f]{6,}/ADDR/g; s/-nan/nan/g' "$1"; }   # the sign of a NaN is not something the tier promises
export NFCXX="$PWD/nfcxx" NFCXX_BACKEND=$be
bad=0; compiled=0; calls=0
for seed in $(seq "$first" $((first + seeds - 1))); do
  python3 tests/ast/fuzz/gen_kernel.py "$seed" "$nf" > "$tmp/p.lua"
  timeout 20 "$lua" "$tmp/p.lua" > "$tmp/ref.raw" 2>&1 || { echo "skip seed $seed: the reference takes too long"; continue; }
  norm "$tmp/ref.raw" > "$tmp/ref.out"
  NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1 timeout 300 "$tmp/driver" --stats "$tmp/p.lua" > "$tmp/tier.raw" 2> "$tmp/tier.err"; norm "$tmp/tier.raw" > "$tmp/tier.out"
  st=$(grep '^tier:' "$tmp/tier.err")
  c=$(sed -E 's/.*compiled=([0-9]+).*/\1/' <<<"$st"); k=$(sed -E 's/.* calls=([0-9]+).*/\1/' <<<"$st")
  compiled=$((compiled + ${c:-0})); calls=$((calls + ${k:-0}))
  if ! cmp -s "$tmp/ref.out" "$tmp/tier.out"; then
    NFCAST_TIER=0 timeout 60 "$tmp/driver" "$tmp/p.lua" > "$tmp/off.raw" 2>&1; norm "$tmp/off.raw" > "$tmp/off.out"
    if cmp -s "$tmp/ref.out" "$tmp/off.out"; then who="TIER"; else who="engine (also without the tier)"; fi
    bad=$((bad + 1)); echo "MISMATCH seed $seed: $who"; diff "$tmp/ref.out" "$tmp/tier.out" | head -6
    cp "$tmp/p.lua" "/tmp/nfcast-tier-fuzz-fail-$seed.lua"; echo "  program kept as /tmp/nfcast-tier-fuzz-fail-$seed.lua"
  fi
done
[ $bad = 0 ] && echo "ok   tier fuzz: $seeds seeds of $nf functions on $be, no mismatch ($compiled functions compiled, $calls calls ran as native code)" || echo "FAIL tier fuzz: $bad program(s) differ"
exit $((bad != 0))
