#!/usr/bin/env bash
# Native DejaGnu invocation using GCC's installed-compiler driver and native
# parallel work allocation. Helpers are local packages, not system installs.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
snapshot=$root/build/testsuite-snapshots
dejagnu=${DEJAGNU_ROOT:-$snapshot/dejagnu}
src=$snapshot/gcc
out=${GCC_SUITE_OUT:-$snapshot/gcc-native-full}
compiler=${GCC_SUITE_CXX:-/usr/bin/g++}
jobs=${SUITE_JOBS:-8}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 1
test -f "$src/contrib/test_installed"
test -x "$dejagnu/usr/bin/runtest"
mkdir -p "$out"; out=$(cd "$out" && pwd)
test ! -e "$out/started" || { echo "choose a fresh GCC_SUITE_OUT: $out" >&2; exit 1; }
touch "$out/started"
mkdir "$out/parallel"
export PATH="$dejagnu/usr/bin:/usr/bin:/bin:$PATH"
export LD_LIBRARY_PATH="$dejagnu/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GCC_RUNTEST_PARALLELIZE_DIR=$out/parallel
"$compiler" --version > "$out/compiler.txt" 2>&1 || true
target=${GCC_SUITE_TARGET:-x86_64-linux-gnu}
export GCC_SUITE_ROOT=$root GCC_SUITE_COMPILER=$compiler GCC_SUITE_TARGET=$target
export GCC_SUITE_SOURCE=$src GCC_SUITE_RESULT=$out
seq 1 "$jobs" | xargs -P "$jobs" -I '{}' bash -c '
  out=$GCC_SUITE_RESULT/worker-$1
  shift
  mkdir "$out"
  cd "$out"
  rc=0
  sh "$GCC_SUITE_SOURCE/contrib/test_installed" \
    --without-gcc --without-gfortran --without-objc \
    --with-g++="$GCC_SUITE_COMPILER" --target="$GCC_SUITE_TARGET" \
    -- "$@" > harness.log 2>&1 || rc=$?
  printf "%s\n" "$rc" > harness.exit
  test -s g++.sum
' worker '{}' "$@"
cat "$out"/worker-*/g++.sum > "$out/combined.sum"
echo "GCC DejaGnu results: $out/combined.sum"
# test_installed itself returns zero after runtest failures; preserve the
# actual assertions in .sum, and fail the wrapper on unexpected outcomes.
if grep -Eq '^(FAIL|XPASS|ERROR|UNRESOLVED):' "$out/combined.sum"; then exit 1; fi
