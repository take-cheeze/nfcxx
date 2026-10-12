#!/usr/bin/env bash
# Parse test: __launch_bounds__ with macro arguments in an included header (llama.cpp's fattn headers) compiles through
# the driver on the host path. It failed before the empty default for __launch_bounds__ in lib/cuda/nfcxx_cuda.h
# ("this declaration has no storage class", "too many template parameters" in the cascade).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ]; then echo "SKIP: parse: needs cuda_runtime.h (CUDA_HOME)"; exit 0; fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
if NFCXX_BACKEND=gcc "$root/nfcxx" -I"$cuda/include" -c hdr_launch_bounds.cu -o "$out/t.o" > "$out/log" 2>&1; then
  echo "parse launch-bounds header: ok"
else
  grep " error" "$out/log" | head -5; echo "parse launch-bounds header: FAIL"; exit 1
fi
