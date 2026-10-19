#!/usr/bin/env bash
# Native Clang harness smoke, including positive and negative diagnostic tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD; src=$root/build/testsuite-snapshots/clang
clang=${CLANG_CXX:-/usr/bin/clang-21}
out=$root/build/testsuite-snapshots/clang-native-smoke
test -x "$clang"
test -f "$src/llvm/utils/lit/lit.py" || { echo 'Run setup-git.sh clang first' >&2; exit 1; }
mkdir -p "$out"
cp tests/upstream/clang-lit.cfg.py "$out/lit.cfg.py"
while IFS=$'\t' read -r id path; do
  [ "$id" = id ] && continue
  ln -sfn "$src/clang/test/$path" "$out/$id.cpp"
done < tests/upstream/clang-smoke.tsv
"$clang" --version > "$out/compiler.txt"
export SMOKE_CLANG=$clang
python3 "$src/llvm/utils/lit/lit.py" -sv -j 2 --timeout 30 --output "$out/results.json" "$out"
