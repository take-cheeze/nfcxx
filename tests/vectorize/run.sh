#!/usr/bin/env bash
# The loop vectorizer of the QBE back end (-ftree-vectorize, 3rd/qbe doc/vectorize.md): each tests/vectorize/*.cpp is
# built with and without the flag. Both builds must print their check (exit 0), and the flagged one must contain packed
# SSE instructions that the plain one does not. amd64 Linux only (the pass is for amd64_sysv); other hosts skip.
cd "$(dirname "$0")/../.."
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  echo "tests/vectorize: skipped (amd64 Linux only)"; exit 0
fi
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
packed() { objdump -d "$1" | grep -c 'addps\|addpd\|mulps\|mulpd\|movups\|paddd'; }
for f in tests/vectorize/*.cpp; do
  name=$(basename "$f" .cpp)
  ./nfcxx --backend=pathb -ftree-vectorize "$f" -o "$tmp/$name.vec" >"$tmp/$name.vec.log" 2>&1 || { echo "FAIL $name: build with -ftree-vectorize"; tail -5 "$tmp/$name.vec.log"; fail=1; continue; }
  ./nfcxx --backend=pathb "$f" -o "$tmp/$name.plain" >"$tmp/$name.plain.log" 2>&1 || { echo "FAIL $name: plain build"; tail -5 "$tmp/$name.plain.log"; fail=1; continue; }
  "$tmp/$name.vec" >"$tmp/$name.vec.out" 2>&1 || { echo "FAIL $name: vectorized program"; cat "$tmp/$name.vec.out"; fail=1; continue; }
  "$tmp/$name.plain" >"$tmp/$name.plain.out" 2>&1 || { echo "FAIL $name: plain program"; cat "$tmp/$name.plain.out"; fail=1; continue; }
  v=$(packed "$tmp/$name.vec"); p=$(packed "$tmp/$name.plain")
  if [ "$v" -gt "$p" ]; then
    echo "ok   $name (packed SSE instructions: $p plain, $v vectorized)"
  else
    echo "FAIL $name: -ftree-vectorize added no packed SSE instructions ($p plain, $v vectorized)"; fail=1
  fi
done
exit $fail
