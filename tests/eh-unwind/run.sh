#!/usr/bin/env bash
# A C++ exception thrown through a frame that QBE compiled: the middle frame (mid.ssa) has no C++ code, so
# its unwind rules come from QBE's .cfi directives alone. The thrower and the catcher are clang/gcc C++.
# Expected: "caught 42" and exit 7. Linux only: the Apple targets emit no unwind info yet.
cd "$(dirname "$0")/../.."
root=$PWD
if [ "$(uname -s)" = Darwin ]; then echo "skip eh-unwind (Apple targets emit no unwind info)"; exit 0; fi
case "$(uname -m)" in
  x86_64) target=amd64_sysv ;;
  aarch64|arm64) target=arm64 ;;
  *) echo "skip eh-unwind (no QBE target for $(uname -m))"; exit 0 ;;
esac
qbe=${NFCXX_QBE:-$root/build/qbe/qbe}
[ -x "$qbe" ] || scripts/setup-qbe.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dir=$root/tests/eh-unwind
"$qbe" -t "$target" "$dir/mid.ssa" > "$tmp/mid.s" || exit 1
cc -c "$tmp/mid.s" -o "$tmp/mid.o" || exit 1
c++ -O0 -c "$dir/thrower.cpp" -o "$tmp/thrower.o" || exit 1
c++ -O0 -c "$dir/catcher.cpp" -o "$tmp/catcher.o" || exit 1
c++ "$tmp/catcher.o" "$tmp/thrower.o" "$tmp/mid.o" -o "$tmp/t" || exit 1
out=$("$tmp/t"); rc=$?
echo "$out"
if [ "$out" = "caught 42" ] && [ $rc -eq 7 ]; then
  echo "ok   eh-unwind throw through QBE frame ($target)"
else
  echo "FAIL eh-unwind throw through QBE frame ($target): exit $rc" >&2
  exit 1
fi
