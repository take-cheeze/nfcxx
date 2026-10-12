#!/usr/bin/env bash
# Differential fuzzing of nfcast against a real Lua 5.4: random expression programs (fuzz/gen_expr.py), random pattern-matching
# programs (fuzz/gen_pat.py) and random small helper functions called from random expressions over changing argument values
# (fuzz/gen_inl.py, for the inlining of calls) run by both; the output, including error messages, must be equal (table addresses
# aside). Not part of CI (the cases in tests/ast/cases are); it found, among others, the float modulo with two negative operands,
# string operands of bitwise operators, and the variable names Lua puts in error messages.
# The helper programs also run with a call site rewritten as soon as it is used twice (NFCAST_INLINE_WARM=1) and, as a check of
# the generator itself, with inlining switched off.
#   tests/ast/fuzz.sh [SEEDS]        (default 100 seeds of each kind; 200 expressions, 150 pattern calls or 40 helper expressions per seed)
#   LUA=/path/to/lua                 the reference (default: built from build/poly-lua/src like regen.sh does)
#   NFCXX_BACKEND=gcc|qbe            back end that builds the driver (default gcc)
cd "$(dirname "$0")/../.."
seeds=${1:-100}
lua=${LUA:-}
if [ -z "$lua" ]; then
  [ -d build/poly-lua/src ] || { echo "fuzz: no Lua source; run scripts/setup-poly-lua.sh, or pass LUA=/path/to/lua" >&2; exit 1; }
  mkdir -p build/ast-ref; lua=build/ast-ref/lua
  [ -x "$lua" ] || (cd build/poly-lua/src && cc -O2 -DLUA_USE_LINUX -o ../../ast-ref/lua $(ls l*.c | grep -v -E '^(luac|onelua|ltests)\.c$') -lm -ldl) || exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
NFCXX_BACKEND=${NFCXX_BACKEND:-gcc} ./nfcxx -O2 -I lib/ast tests/ast/driver.cpp lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp \
  lib/ast/nfcast_parse.cpp lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp lib/ast/nfcast_tier.cpp -o "$tmp/driver" || exit 1
bad=0
for kind in expr pat inl; do
  envs=("")
  [ $kind = inl ] && envs=("NFCAST_INLINE_WARM=2" "NFCAST_INLINE_WARM=1" "NFCAST_INLINE=0")
  for seed in $(seq 1 "$seeds"); do
    n=200; [ $kind = pat ] && n=150; [ $kind = inl ] && n=40
    python3 tests/ast/fuzz/gen_$kind.py "$seed" $n > "$tmp/p.lua"
    "$lua" "$tmp/p.lua" 2>&1 | sed -E 's/0x[0-9a-f]{6,}/ADDR/g' > "$tmp/ref.out"
    for e in "${envs[@]}"; do
      env $e "$tmp/driver" "$tmp/p.lua" 2>&1 | sed -E 's/0x[0-9a-f]{6,}/ADDR/g' > "$tmp/ast.out"
      if ! cmp -s "$tmp/ref.out" "$tmp/ast.out"; then
        bad=$((bad + 1)); echo "MISMATCH $kind seed $seed ($e)"; diff "$tmp/ref.out" "$tmp/ast.out" | head -6
      fi
    done
  done
done
[ $bad = 0 ] && echo "ok   fuzz: $seeds seeds of each kind, no mismatch" || echo "FAIL fuzz: $bad program(s) differ"
exit $((bad != 0))
