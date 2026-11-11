#!/usr/bin/env bash
# The Path B front end built for the browser (PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh, run under node by
# scripts/pathb-dump-wasm.cjs) against the native one (scripts/pathb-dump): for each C and C++ file below, the IR
# (--ir, with NFCXX_IR_LOC=1) and the exit status must be the same, byte for byte. docs/notes/pathb-wasm-frontend.md.
#   tests/pathb-wasm-frontend/run.sh [FILE...]   the files below, or these
# Skips (exit 0) when either front end is not built or node is missing.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ -x build/pathb/cmake/bin/cpfe ] || { echo "skip: native front end not built (scripts/setup-pathb.sh)"; exit 0; }
[ -f build/pathb-wasm/cmake/bin/cpfe.js ] || { echo "skip: browser front end not built (PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh)"; exit 0; }
command -v node >/dev/null || { echo "skip: node not found"; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

if [ $# -gt 0 ]; then files=("$@"); else
  files=(tests/cases/*.cpp tests/cases/*.c tests/wasm/*.cpp tests/c/*.c tests/builtins/*.c tests/builtins/*.cpp
         tests/pathb-ir/*.c tests/pathb-ir/*.cpp tools/wasm-explorer/examples/*.c tools/wasm-explorer/examples/*.cpp)
fi
known=$(grep -v '^#' "$(dirname "$0")/known.txt" | grep -v '^$')
pass=0; fail=0; nknown=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  n=${f//\//_}
  is_known=0; grep -qxF "$f" <<< "$known" && is_known=1
  NFCXX_IR_LOC=1 scripts/pathb-dump --ir "$f" > "$work/$n.native" 2> "$work/$n.native.err"; ns=$?
  NFCXX_IR_LOC=1 node scripts/pathb-dump-wasm.cjs --ir "$f" > "$work/$n.wasm" 2> "$work/$n.wasm.err"; ws=$?
  if [ $is_known = 1 ]; then
    if [ $ns = $ws ] && cmp -s "$work/$n.native" "$work/$n.wasm"; then
      echo "FAIL $f: listed in known.txt but the IR is the same now (remove the entry)"; fail=$((fail + 1))
    else
      echo "known $f (known.txt)"; nknown=$((nknown + 1))
    fi
  elif [ $ns != $ws ]; then
    echo "FAIL $f: exit $ns native, $ws wasm: $(head -3 "$work/$n.wasm.err" | tr '\n' ' ')"; fail=$((fail + 1))
  elif ! cmp -s "$work/$n.native" "$work/$n.wasm"; then
    echo "FAIL $f: the IR differs"; diff "$work/$n.native" "$work/$n.wasm" | head -6; fail=$((fail + 1))
  else
    echo "ok   $f (exit $ns, $(wc -l < "$work/$n.wasm") lines)"; pass=$((pass + 1))
  fi
done
echo "tests/pathb-wasm-frontend: $pass passed, $fail failed, $nknown known differences"
[ $fail = 0 ]
