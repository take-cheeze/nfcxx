#!/usr/bin/env bash
# Installed-library mode documented by upstream; preserve DejaGnu assertions.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
base=$root/build/testsuite-snapshots
dejagnu=${DEJAGNU_ROOT:-$base/dejagnu}
test -x "$dejagnu/usr/bin/runtest"
out=${LIBSTDCXX_SUITE_OUT:-$base/libstdcxx-native-full}
jobs=${SUITE_JOBS:-8}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 1
mkdir -p "$out"; out=$(cd "$out" && pwd)
test ! -e "$out/started" || { echo "choose a fresh LIBSTDCXX_SUITE_OUT" >&2; exit 1; }
date -u +%FT%TZ > "$out/started"
mkdir "$out/parallel"
export PATH="$dejagnu/usr/bin:/usr/bin:/bin:$PATH"
export LD_LIBRARY_PATH="$dejagnu/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GCC_RUNTEST_PARALLELIZE_DIR=$out/parallel
export LIBSTDCXX_SOURCE=$base/gcc/libstdc++-v3/testsuite LIBSTDCXX_RESULT=$out
g++ --version > "$out/compiler.txt"
seq 1 "$jobs" | xargs -P "$jobs" -I '{}' bash -c '
  worker=$LIBSTDCXX_RESULT/worker-$1
  shift
  mkdir "$worker"; cd "$worker"
  rc=0
  runtest --tool libstdc++ --srcdir="$LIBSTDCXX_SOURCE" "$@" > harness.log 2>&1 || rc=$?
  printf "%s\n" "$rc" > harness.exit
  test -s libstdc++.sum
' worker '{}' "$@"
cat "$out"/worker-*/libstdc++.sum > "$out/combined.sum"
date -u +%FT%TZ > "$out/completed"
echo "libstdc++ native results: $out/combined.sum"
if grep -Eq '^(FAIL|XPASS|ERROR|UNRESOLVED):' "$out/combined.sum"; then exit 1; fi
