#!/usr/bin/env bash
# Compile each tests/cases/*.cpp with nfcxx (backend: $NFCXX_BACKEND, default qbe) and compare the exit code with `// EXPECT: N`.
# Markers (first matching line of a test):
#   // X86-ONLY: reason          depends on the x86-64 target; skipped on every other host.
#   // X86-ONLY-LINUX: reason    depends on the x86-64 long double layout of the Linux front end; skipped on non-x86-64
#                                Linux only (macOS arm64 runs it).
#   // MACOS-XFAIL-<backend>: reason   a documented macOS-only failure of that backend: reported as xfail on Darwin. A pass
#                                there is an XPASS and fails the run, so the marker gets removed.
cd "$(dirname "$0")/.."
be=${NFCXX_BACKEND:-qbe}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in tests/cases/*.cpp; do
  if x86only=$(sed -n 's,^// X86-ONLY: *\(.*\),\1,p' "$f" | head -1); [ -n "$x86only" ] && [ "$(uname -m)" != x86_64 ]; then
    echo "skip $f (x86-64 only: $x86only)"; continue
  fi
  if linuxonly=$(sed -n 's,^// X86-ONLY-LINUX: *\(.*\),\1,p' "$f" | head -1); [ -n "$linuxonly" ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" != x86_64 ]; then
    echo "skip $f (x86-64 Linux only: $linuxonly)"; continue
  fi
  xf=""
  [ "$(uname -s)" = Darwin ] && xf=$(sed -n "s,^// MACOS-XFAIL-$be: *,,p" "$f" | head -1)
  want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$f" | head -1)
  if ! ./nfcxx "$f" -o "$tmp/t" 2>"$tmp/err"; then
    if [ -n "$xf" ]; then echo "xfail $f (compile): $xf"; continue; fi
    echo "FAIL (compile) $f"; head -30 "$tmp/err"; fail=1; continue
  fi
  "$tmp/t"; got=$?
  if [ $((got & 255)) -eq $((want & 255)) ]; then
    if [ -n "$xf" ]; then echo "XPASS $f: remove the MACOS-XFAIL-$be marker"; fail=1; else echo "ok   $f"; fi
  elif [ -n "$xf" ]; then echo "xfail $f (run, want $want got $got): $xf"
  else echo "FAIL $f: want $want got $got"; fail=1; fi
done
exit $fail
