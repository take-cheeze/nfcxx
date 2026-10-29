#!/usr/bin/env bash
# A kernel whose body comes from a header next to the source, and a device helper from that header's own directory
# (the device pass, not only the host copy). Exact output on the GPU. Skips without the CUDA toolkit or a GPU.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
export NFCXX_BACKEND=gcc
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: devpass: needs cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
if ! "$root/nfcxx" -c -I"$cuda/include" a.cu -o "$out/a.o" > "$out/build.log" 2>&1 \
   || ! "$root/nfcxx" "$out/a.o" -L"$cuda/lib64" -lcudart -o "$out/a" >> "$out/build.log" 2>&1; then
  cat "$out/build.log"; echo "devpass: FAIL (build)"; exit 1
fi
run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/a") && rc=0 || rc=$?
if [ "$rc" = 0 ] && grep -q "0 mismatches" <<<"$run"; then echo "devpass: ok ($run)"; else echo "devpass: FAIL (exit $rc): $run"; exit 1; fi
