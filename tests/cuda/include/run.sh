#!/usr/bin/env bash
# Quoted includes relative to a .cu source: a.cu includes "sub/helper.cuh", which includes "../inc/common.cuh".
# The driver compiles a cached copy of a.cu, so these resolve through the source's own directory (-I added for .cu
# inputs). Builds, links and runs a kernel that uses the header chain on the GPU. Skips (exit 0) without the CUDA
# toolkit, libcudart or an NVIDIA GPU (CUDA_HOME, default /usr/local/cuda).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
# The CUDA runtime headers do not compile on the qbe backend (cproc), so this test uses gcc.
export NFCXX_BACKEND=gcc
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: cuda include: needs cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
if ! "$root/nfcxx" -c -I"$cuda/include" -I"$cuda/include/cccl" a.cu -o "$out/a.o" > "$out/build.log" 2>&1 \
   || ! "$root/nfcxx" "$out/a.o" -L"$cuda/lib64" -lcudart -o "$out/a" >> "$out/build.log" 2>&1; then
  cat "$out/build.log"; echo "cuda include: FAIL (build)"; exit 1
fi
run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/a") && rc=0 || rc=$?
if [ "$rc" = 0 ] && grep -q "0 mismatches" <<<"$run"; then echo "cuda include: ok ($run)"; else echo "cuda include: FAIL (exit $rc): $run"; exit 1; fi
