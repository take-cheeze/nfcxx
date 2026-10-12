#!/usr/bin/env bash
# nfcuop (lib/uop, docs/notes/uop.md), per back end built with nfcxx and run:
#   - tests/uop/test.cpp      scalar core: interning, interpreter, patterns, graph_rewrite, the symbolic simplifier,
#                             and a differential check of the simplifier against the interpreter on random expressions
#   - tests/uop/test_np.cpp   shapes, movement ops, reductions, tensor rewrites (also differential), and the numpy-like
#                             Tensor API of nfcuop_np.hpp
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   UOP_HOST=1              build with the host g++ (-fsanitize=address,undefined) and nothing else; for a machine
#                           where nfcxx is not built
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
lib=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_np.cpp)
tests=(test test_np)
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "$UOP_HOST" ]; then
  for t in "${tests[@]}"; do
    if out=$(g++ -std=c++17 -Wall -Wextra -O1 -fsanitize=address,undefined -I lib/uop tests/uop/$t.cpp "${lib[@]}" -o "$tmp/host-$t" 2>&1) &&
       res=$("$tmp/host-$t" 2>&1); then echo "ok   host g++ uop/$t: $(tail -1 <<<"$res")"
    else echo "FAIL host g++ uop/$t"; echo "$out${res:+$'\n'$res}" | head -30; fail=1; fi
  done
  exit $fail
fi
for be in $backends; do
  for t in "${tests[@]}"; do
    if ! out=$(NFCXX_BACKEND=$be ./nfcxx -O2 -I lib/uop tests/uop/$t.cpp "${lib[@]}" -o "$tmp/$be-$t" 2>&1); then
      echo "FAIL $be uop/$t (build)"; head -30 <<<"$out"; fail=1; continue
    fi
    if res=$("$tmp/$be-$t" 2>&1); then echo "ok   $be uop/$t: $(tail -1 <<<"$res")"
    else echo "FAIL $be uop/$t"; head -30 <<<"$res"; fail=1; fi
  done
done
exit $fail
