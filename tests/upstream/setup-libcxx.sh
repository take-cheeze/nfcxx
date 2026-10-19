#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/bin:/bin:$PATH
unset CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH
/usr/bin/python3 -c 'import psutil'
cd "$(dirname "$0")/../.."
tests/upstream/setup-git.sh clang
if [ -n "${CLANG_TIDY_EXE:-}" ]; then
  test -x "$CLANG_TIDY_EXE"
else
  tests/upstream/setup-clang-tidy.sh
fi
base=$PWD/build/testsuite-snapshots
cmake -G Ninja -S "$base/clang/runtimes" -B "$base/libcxx-build-system" \
  -DCMAKE_C_COMPILER=/usr/bin/clang-21 -DCMAKE_CXX_COMPILER=/usr/bin/clang++-21 \
  '-DLLVM_ENABLE_RUNTIMES=libcxx;libcxxabi;libunwind' -DCMAKE_BUILD_TYPE=Release \
  -DPython3_EXECUTABLE=/usr/bin/python3 -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLIBCXX_INCLUDE_TESTS=ON -DLIBCXXABI_INCLUDE_TESTS=ON -DLIBUNWIND_INCLUDE_TESTS=ON \
  -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLLVM_USE_LINKER=lld
cmake --build "$base/libcxx-build-system" --target cxx-test-depends cxxabi-test-depends unwind -j "${SUITE_JOBS:-8}"
