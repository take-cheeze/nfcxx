#!/usr/bin/env bash
# __int128 and unsigned __int128 through the qbe backend (cproc's soft 128-bit integers, be/nfcxx_ldrt.c helpers): each
# program's output must equal the output of the same program built by gcc (tests/int128/*.expected were made with gcc).
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
for src in tests/int128/*.c; do
  name=$(basename "$src" .c)
  if ! NFCXX_BACKEND=qbe ./nfcxx "$src" -o "$tmp/$name" > "$tmp/$name.log" 2>&1; then
    echo "FAIL build $name (see the log)"; cat "$tmp/$name.log" | head -5; fail=1; continue
  fi
  if "$tmp/$name" | diff -q - "tests/int128/$name.expected" > /dev/null; then
    echo "ok   $name"
  else
    echo "FAIL output $name"; "$tmp/$name" | diff - "tests/int128/$name.expected" | head -5; fail=1
  fi
done
echo "$fail failures"
exit $fail
