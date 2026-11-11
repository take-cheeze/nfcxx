#!/usr/bin/env bash
# Deterministic source inventories; a source count is not an execution count.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD/build/testsuite-snapshots
rg --files --no-ignore "$root/gcc/gcc/testsuite/g++.dg" "$root/gcc/gcc/testsuite/g++.old-deja" \
  "$root/gcc/gcc/testsuite/g++.target" -g '*.C' -g '*.cpp' | sort | \
  sed "s|^$root/gcc/||" > "$root/gcc-files.txt"
scripts/mrb tests/upstream/gcc-index.rb "$root/gcc" "$root/gcc-files.txt" > "$root/gcc-inventory.tsv"
rg --files --no-ignore "$root/clang/clang/test" -g '*.cpp' -g '*.c' -g '*.test' | sort > "$root/clang-files.txt"
rg --files --no-ignore "$root/llvm-test-suite/SingleSource" "$root/llvm-test-suite/MultiSource" \
  -g '*.cpp' -g '*.c' | sort > "$root/llvm-test-suite-files.txt"
echo "Inventories: $root/{gcc-inventory.tsv,clang-files.txt,llvm-test-suite-files.txt}"
