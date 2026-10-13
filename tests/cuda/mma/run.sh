#!/usr/bin/env bash
# Tensor-core matmul (mma.sync.aligned.m16n8k8 f16, the form of llama.cpp's mma.cuh) through the driver: the result is
# checked against the host product (exact: small integers). A mutant that swaps two A operands must fail.
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: mma: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
export TMPDIR=$out
build_run() {  # build_run SRC NAME: prints the program's output
  "$root/nfcxx" -c -I"$cuda/include" "$1" -o "$out/$2.o" > "$out/$2.log" 2>&1 || { cat "$out/$2.log" | grep -v "pragma\|NV_SILENCE\|^ *\^\|warning\|^ *$" | head -5; return 1; }
  "$root/nfcxx" "$out/$2.o" -L"$cuda/lib64" -lcudart -o "$out/$2" >> "$out/$2.log" 2>&1 || return 1
  LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$2" || true
}
fail=0
run=$(build_run mma.cu mma) || { echo "FAIL mma: build"; exit 1; }
if [[ "$run" == *"no error, 0 mismatches"* ]]; then echo "pass mma: $run"; else echo "FAIL mma: $run"; fail=1; fi
# Mutant: the A operands of the mma are swapped (a0 and a1): the result must change.
sed 's/{%4, %5}/{%5, %4}/' mma.cu > "$out/mut.cu"
mrun=$(build_run "$out/mut.cu" mut) || true
if [[ "$mrun" == *"no error, 0 mismatches"* ]]; then echo "FAIL mutant mma: not caught"; fail=1; else echo "mutant mma: caught ($mrun)"; fi
exit $fail
