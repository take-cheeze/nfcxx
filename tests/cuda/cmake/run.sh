#!/usr/bin/env bash
# CMake's CUDA route: a one-kernel project configured and built with scripts/nfcxx-cuda as CMAKE_CUDA_COMPILER.
# Needs cmake, the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and a gcc host compiler. Skips (exit 0) otherwise.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if ! command -v cmake >/dev/null || [ ! -x "$cuda/bin/nvcc" ] || [ ! -f "$cuda/include/cuda_runtime.h" ]; then
  echo "SKIP: cuda cmake: needs cmake and the CUDA toolkit (CUDA_HOME)"; exit 0
fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
cmake -S . -B "$out/build" -G Ninja -DCMAKE_CUDA_COMPILER="$root/scripts/nfcxx-cuda" -DCUDAToolkit_ROOT="$cuda" \
  -DCMAKE_CUDA_COMPILER_TOOLKIT_ROOT="$cuda" > "$out/configure.log" 2>&1 \
  || { cat "$out/configure.log"; echo "cuda cmake: FAIL (configure)"; exit 1; }
cmake --build "$out/build" -j4 > "$out/build.log" 2>&1 \
  || { cat "$out/build.log"; echo "cuda cmake: FAIL (build)"; exit 1; }
[ -f "$out/build/libkernel.a" ] || { echo "cuda cmake: FAIL (no libkernel.a)"; exit 1; }
echo "cuda cmake: ok (configure and build through scripts/nfcxx-cuda)"
