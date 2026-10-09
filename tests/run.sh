#!/usr/bin/env bash
# Compile each tests/cases/*.cpp with nfcxx (backend: $NFCXX_BACKEND, default qbe) and compare the exit code with `// EXPECT: N`.
cd "$(dirname "$0")/.."
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in tests/cases/*.cpp; do
  want=$(sed -n 's,^// EXPECT: *\(-\?[0-9]*\).*,\1,p' "$f" | head -1)
  if ! ./nfcxx "$f" -o "$tmp/t" 2>"$tmp/err"; then
    echo "FAIL (compile) $f"; head -5 "$tmp/err"; fail=1; continue
  fi
  "$tmp/t"; got=$?
  [ $((got & 255)) -eq $((want & 255)) ] && echo "ok   $f" || { echo "FAIL $f: want $want got $got"; fail=1; }
done
exit $fail
