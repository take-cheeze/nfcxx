#!/usr/bin/env bash
# Builtin probes: compile each tests/builtins/*.cpp with nfcxx (--gnu-version=130000, see docs/notes/builtins.md)
# and compare the exit code with `// EXPECT: N`. Runs both backends unless NFCXX_BACKEND is set.
# Header lines (first lines of a test):
#   // DIALECT: clang           compile in the clang front-end mode (default g++).
#   // XFAIL-qbe: <reason>      known failure on the qbe backend; reported as xfail.
#   // XFAIL-gcc: <reason>      same for the gcc backend. An XFAIL that passes is a failure (remove the marker).
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for be in $backends; do
  for f in tests/builtins/*.cpp; do
    name=$(basename "$f" .cpp)
    want=$(sed -n 's,^// EXPECT: *\(-\?[0-9]*\).*,\1,p' "$f" | head -1)
    dialect=$(sed -n 's,^// DIALECT: *\(.*\),\1,p' "$f" | head -1)
    xfail=$(sed -n "s,^// XFAIL-$be: *\(.*\),\1,p" "$f" | head -1)
    if ./nfcxx --gnu-version=130000 ${dialect:+--dialect=$dialect} --backend="$be" "$f" -o "$tmp/t" 2>"$tmp/err"; then
      "$tmp/t" >/dev/null 2>&1; got=$?
      if [ $((got & 255)) -eq $((want & 255)) ]; then st=ok; else st=FAIL; fi
    else
      got=compile; st=FAIL
    fi
    if [ -n "$xfail" ]; then
      if [ "$st" = ok ]; then echo "XPASS $be $name (remove the XFAIL-$be marker)"; fail=1
      else echo "xfail $be $name: $xfail"; fi
      continue
    fi
    if [ "$st" = ok ]; then echo "ok    $be $name"
    else
      echo "FAIL  $be $name: want $want got $got"; head -4 "$tmp/err"; fail=1
    fi
  done
done
exit $fail
