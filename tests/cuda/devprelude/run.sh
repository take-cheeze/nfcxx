#!/usr/bin/env bash
# std::is_same_v and std::is_same in device code, through the driver: traits.cu's kernels give 1/10 for float and 0/0
# for int. Needs CUDA_HOME and an NVIDIA GPU; skips (exit 0) when they are missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: devprelude: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
export TMPDIR=$out NFCXX_BACKEND=${NFCXX_BACKEND:-gcc}
want=$'no error float 1 10\nno error int 0 0'
if "$root/nfcxx" -c -I"$cuda/include" traits.cu -o "$out/t.o" > "$out/log" 2>&1 \
   && "$root/nfcxx" "$out/t.o" -L"$cuda/lib64" -lcudart -o "$out/t" >> "$out/log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/t") && [ "$run" = "$want" ]; then
  echo "ok devprelude: is_same_v and is_same on the GPU"; exit 0
fi
echo "FAIL devprelude"; cat "$out/log" | grep -v "warning\|pragma\|^ *\^" | head -5; echo "run: ${run:-}"; exit 1
