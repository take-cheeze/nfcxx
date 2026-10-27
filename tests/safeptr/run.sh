#!/usr/bin/env bash
# Safe pointers (nfcxx -fsafe-pointers; docs/notes/safe-pointers.md): Fil-C-style checks emitted from the Path B IR.
#
#   tests/safeptr/cases/*.cpp  with a `// SAFE: text` line: the program must abort (status 134) with
#                              "FILE:LINE: safety error: text" on stderr, FILE the program's source; built without the
#                              flag, the same program must not report anything.
#                              with `// EXPECT: N`: the program must exit N with the flag, and nothing on stderr.
#   SAFEPTR_SWEEP=1            also build every tests/pathb-qbe/cases and tests/cases program with and without the flag:
#                              the exit status and standard output must be the same (no false positives; a few minutes).
# Needs the Path B harness (scripts/setup-pathb.sh) and EDG's runtime (scripts/setup-edg.sh). Exit 2 without them.
cd "$(dirname "$0")/../.."
root=$PWD; nfcxx=$root/nfcxx
[ -x build/pathb/cmake/bin/cpfe ] || { echo "safeptr: no Path B harness (scripts/setup-pathb.sh)" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

for f in tests/safeptr/cases/*.cpp; do
  n=$(basename "$f" .cpp)
  want=$(sed -n 's,^// SAFE: *\(.*\),\1,p' "$f" | head -1)
  expect=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
  if ! "$nfcxx" -fsafe-pointers "$f" -o "$tmp/$n" 2>"$tmp/err"; then bad "$n" "compile: $(grep -v warning "$tmp/err" | head -3 | tr '\n' ' ')"; continue; fi
  "$tmp/$n" >"$tmp/out" 2>"$tmp/rep"; rc=$?
  if [ -n "$want" ]; then
    if [ $rc -ne 134 ]; then bad "$n" "exit $rc, expected the abort (134): $(head -2 "$tmp/rep" | tr '\n' ' ')"
    elif ! grep -qF -- "safety error: $want" "$tmp/rep"; then bad "$n" "report lacks '$want': $(head -1 "$tmp/rep")"
    elif ! grep -q "^\(free\|realloc\|$root/$f\):[0-9]*: safety error" "$tmp/rep"; then bad "$n" "report does not name the source: $(head -1 "$tmp/rep")"
    else
      # without the flag nothing reports (the program is wrong, so its exit status is not checked)
      if "$nfcxx" --backend=pathb "$f" -o "$tmp/$n.off" 2>/dev/null; then
        "$tmp/$n.off" >/dev/null 2>"$tmp/rep.off"
        if grep -q "safety error" "$tmp/rep.off"; then bad "$n" "reports without -fsafe-pointers"; continue; fi
      fi
      ok "$n"
    fi
  else
    if [ "$rc" != "${expect:-0}" ] || [ -s "$tmp/rep" ]; then bad "$n" "exit $rc (expected ${expect:-0}): $(head -2 "$tmp/rep" | tr '\n' ' ')"; else ok "$n"; fi
  fi
done

# Driver: refusals
if "$nfcxx" -fsafe-pointers --freestanding tests/safeptr/cases/clean_containers.cpp -o "$tmp/x" 2>/dev/null; then bad driver "--freestanding accepted"; else ok "driver: --freestanding refused"; fi
if "$nfcxx" -fsafe-pointers -fsanitize=address tests/safeptr/cases/clean_containers.cpp -o "$tmp/x" 2>/dev/null; then bad driver "-fsanitize=address accepted"; else ok "driver: -fsanitize=address refused"; fi

if [ "${SAFEPTR_SWEEP:-0}" = 1 ]; then
  for f in tests/pathb-qbe/cases/*.cpp tests/cases/*.cpp; do
    n=$(echo "$f" | tr / _); std=$(sed -n 's,^// STD: *\(c++[0-9]*\).*,-std=\1,p' "$f" | head -1)
    "$nfcxx" --backend=pathb $std "$f" -o "$tmp/$n.base" 2>/dev/null || { echo "skip $f (Path B does not build it)"; continue; }
    if ! "$nfcxx" -fsafe-pointers $std "$f" -o "$tmp/$n.safe" 2>"$tmp/err"; then bad "$f" "compile: $(grep -v warning "$tmp/err" | head -2 | tr '\n' ' ')"; continue; fi
    (cd "$tmp" && timeout 20 "./$n.base" >"$n.bout" 2>/dev/null); a=$?
    (cd "$tmp" && timeout 120 "./$n.safe" >"$n.sout" 2>"$n.serr"); b=$?
    if [ $a != $b ] || ! cmp -s "$tmp/$n.bout" "$tmp/$n.sout"; then bad "$f" "exit $a without the flag, $b with it: $(head -c 200 "$tmp/$n.serr")"; else ok "$f"; fi
    rm -f "$tmp/$n".*
  done
fi

echo "safeptr: $pass passed, $fail failed"
[ $fail = 0 ]
