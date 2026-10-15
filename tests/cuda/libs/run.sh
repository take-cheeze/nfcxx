#!/usr/bin/env bash
# CUDA library linking: a .cu file that includes cuBLAS and cuDNN, with a device kernel, is compiled through nfcxx and
# through nfcxx-cuda (the CMake path, which passes the toolkit include directory with -I), and linked with
# -lcublas -lcudnn -lcudart. Nothing is run: the program needs a GPU and the driver. Skips (exit 0) when the libraries are missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cublas_v2.h" ] || [ ! -f "$cuda/include/cudnn.h" ] || [ ! -e "$cuda/lib64/libcublas.so" ] \
   || [ ! -e "$cuda/lib64/libcudnn.so" ] || [ ! -e "$cuda/lib64/libcudart.so" ]; then
  echo "SKIP: cuda libs: needs cublas_v2.h, cudnn.h, libcublas, libcudnn and libcudart (CUDA_HOME)"; exit 0
fi
libdir=$cuda/lib64
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
inc=(-I"$cuda/include")
[ -d "$cuda/include/cccl" ] && inc+=(-I"$cuda/include/cccl")

if "$root/nfcxx" "${inc[@]}" blas_cudnn.cu -L"$libdir" -lcublas -lcudnn -lcudart -o "$out/direct" > "$out/direct.log" 2>&1 \
   && ldd "$out/direct" | grep -q libcublas && ldd "$out/direct" | grep -q libcudnn; then
  echo "cublas+cudnn through nfcxx: ok"
else
  cat "$out/direct.log"; echo "cublas+cudnn through nfcxx: FAIL"; fail=1
fi
if CUDA_HOME="$cuda" "$root/scripts/nfcxx-cuda" -c blas_cudnn.cu -o "$out/cu.o" > "$out/cu.log" 2>&1 \
   && "$root/nfcxx" "$out/cu.o" -L"$libdir" -lcublas -lcudnn -lcudart -o "$out/cmake" > "$out/link.log" 2>&1; then
  echo "cublas+cudnn through nfcxx-cuda: ok"
else
  cat "$out/cu.log" "$out/link.log" 2>/dev/null || true; echo "cublas+cudnn through nfcxx-cuda: FAIL"; fail=1
fi
[ "$fail" = 0 ] && echo "cuda libs: all ok" || { echo "cuda libs: FAILED"; exit 1; }
