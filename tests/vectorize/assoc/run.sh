#!/usr/bin/env bash
# -fassociative-math lets the vectorizer reassociate a float sum (qbe -F, 3rd/qbe vec.c vecassoc): with the flag the
# loop of each tests/vectorize/assoc/*.cpp gets packed SSE adds, without it the loop stays scalar. Both builds print
# the same line (the sums are exact here). amd64 Linux only; other hosts skip.
cd "$(dirname "$0")/../../.."
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  echo "tests/vectorize/assoc: skipped (amd64 Linux only)"; exit 0
fi
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# the packed adds and multiplies of the program (its only loop is the sum; main has none)
packed() { objdump -d "$1" | grep -c "addps\\|mulps"; }
for f in tests/vectorize/assoc/*.cpp; do
  name=$(basename "$f" .cpp)
  ./nfcxx --backend=pathb "$f" -o "$tmp/$name.plain" >"$tmp/$name.plain.log" 2>&1 || { echo "FAIL $name: build"; tail -5 "$tmp/$name.plain.log"; fail=1; continue; }
  ./nfcxx --backend=pathb -fassociative-math "$f" -o "$tmp/$name.assoc" >"$tmp/$name.assoc.log" 2>&1 || { echo "FAIL $name: build with -fassociative-math"; tail -5 "$tmp/$name.assoc.log"; fail=1; continue; }
  "$tmp/$name.plain" >"$tmp/$name.plain.out" 2>&1 || { echo "FAIL $name: plain program"; cat "$tmp/$name.plain.out"; fail=1; continue; }
  "$tmp/$name.assoc" >"$tmp/$name.assoc.out" 2>&1 || { echo "FAIL $name: reassociated program"; cat "$tmp/$name.assoc.out"; fail=1; continue; }
  if ! cmp -s "$tmp/$name.plain.out" "$tmp/$name.assoc.out"; then
    echo "FAIL $name: the outputs differ"; fail=1; continue
  fi
  p=$(packed "$tmp/$name.plain"); v=$(packed "$tmp/$name.assoc")
  if [ "$p" -eq 0 ] && [ "$v" -gt 0 ]; then
    echo "ok   $name (packed float ops: $p plain, $v with -fassociative-math)"
  else
    echo "FAIL $name: packed float ops: $p plain, $v with -fassociative-math (want 0 and more than 0)"; fail=1
  fi
done
exit $fail
