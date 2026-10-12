#!/usr/bin/env bash
# nfcuop (lib/uop, docs/notes/uop.md): tests/uop/test.cpp linked with the three library files, built with nfcxx per
# back end and run: interning, the interpreter, patterns, graph_rewrite, the symbolic simplifier, and a differential
# check of the simplifier against the interpreter on random expressions.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   UOP_HOST=1              also build with the host g++ (-fsanitize=address,undefined); only that when nfcxx is not built
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
srcs=(tests/uop/test.cpp lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp)
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "$UOP_HOST" ]; then
  if out=$(g++ -std=c++17 -Wall -Wextra -O1 -fsanitize=address,undefined -I lib/uop "${srcs[@]}" -o "$tmp/host" 2>&1) &&
     res=$("$tmp/host" 2>&1); then echo "ok   host g++ uop: $(tail -1 <<<"$res")"
  else echo "FAIL host g++ uop"; echo "$out${res:+$'\n'$res}" | head -30; fail=1; fi
fi
if [ -z "$UOP_HOST" ] || [ -x ./build/edg/cpfe ] || [ -d build/edg ]; then
  for be in $backends; do
    if ! out=$(NFCXX_BACKEND=$be ./nfcxx -O2 -I lib/uop "${srcs[@]}" -o "$tmp/$be" 2>&1); then
      echo "FAIL $be uop (build)"; head -30 <<<"$out"; fail=1; continue
    fi
    if res=$("$tmp/$be" 2>&1); then echo "ok   $be uop: $(tail -1 <<<"$res")"
    else echo "FAIL $be uop"; head -30 <<<"$res"; fail=1; fi
  done
fi
exit $fail
