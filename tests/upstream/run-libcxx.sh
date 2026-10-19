#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/bin:/bin:$PATH
cd "$(dirname "$0")/../.."
base=$PWD/build/testsuite-snapshots
out=${LIBCXX_SUITE_OUT:-$base/libcxx-native-full}
mkdir -p "$out"; out=$(cd "$out" && pwd)
test ! -e "$out/started" || { echo 'choose a fresh LIBCXX_SUITE_OUT' >&2; exit 1; }
"${SUITE_PYTHON:-/usr/bin/python3}" -c 'import psutil'
/usr/bin/clang++-21 --version > "$out/compiler.txt"
cp tests/upstream/git-snapshots.tsv "$out/"
extra=()
tidy=${CLANG_TIDY_EXE:-$base/clang-tidy/usr/lib/llvm-21/bin/clang-tidy}
if [ -x "$tidy" ]; then extra+=(--param "clang-tidy-executable=$tidy"); fi
date -u +%FT%TZ > "$out/started"
rc=0
"${SUITE_PYTHON:-/usr/bin/python3}" "$base/clang/llvm/utils/lit/lit.py" -sv -j "${SUITE_JOBS:-8}" \
  --timeout "${SUITE_TIMEOUT:-120}" --output "$out/results.json" \
  "$base/libcxx-build-system/libcxx/test" "${extra[@]}" "$@" > "$out/harness.log" 2>&1 || rc=$?
date -u +%FT%TZ > "$out/completed"
echo "libc++ native results: $out/results.json"
exit "$rc"
