#!/usr/bin/env bash
# Configure the actual upstream CMake/lit harness with installed LLVM tools.
set -euo pipefail
cd "$(dirname "$0")/../.."
tests/upstream/setup-git.sh llvm-test-suite
src=$PWD/build/testsuite-snapshots/llvm-test-suite
out=${LLVM_TEST_SUITE_OUT:-$PWD/build/testsuite-snapshots/llvm-test-suite-host}
cmake -S "$src" -B "$out" -G Ninja \
  -DCMAKE_C_COMPILER=/usr/bin/clang-21 -DCMAKE_CXX_COMPILER=/usr/bin/clang++-21 \
  -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER= \
  -DTEST_SUITE_SUBDIRS=SingleSource \
  -DTEST_SUITE_COLLECT_CODE_SIZE=OFF
cmake --build "$out" --target Shootout-C++-hello build-fpcmp build-timeit -j 2
python3 build/testsuite-snapshots/clang/llvm/utils/lit/lit.py -sv --timeout 30 \
  --output "$out/smoke-results.json" "$out/SingleSource/Benchmarks/Shootout-C++/Shootout-C++-hello.test"
