#!/usr/bin/env bash
# Two translation units that include one header with a kernel and an unused static __device__ helper. Each unit has
# its own host copy of the kernel (internal linkage, as nvcc gives), so they link; the device code is one image per
# unit and the kernel runs from either. The mutant (+2 in the kernel) must fail. Needs CUDA_HOME and an NVIDIA GPU;
# skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: linkage: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out
export NFCXX_BACKEND=gcc  # the CUDA runtime headers do not compile on the qbe backend
fail=0

build_run() {  # build_run DIR TAG: builds both units from DIR, links, runs; prints the run line
  local d=$1 tag=$2
  "$root/nfcxx" -c -I"$cuda/include" "$d/unit_a.cu" -o "$out/$tag.a.o" > "$out/$tag.log" 2>&1 || return 1
  "$root/nfcxx" -c -I"$cuda/include" "$d/unit_b.cu" -o "$out/$tag.b.o" >> "$out/$tag.log" 2>&1 || return 1
  "$root/nfcxx" "$out/$tag.a.o" "$out/$tag.b.o" -L"$cuda/lib64" -lcudart -o "$out/$tag" >> "$out/$tag.log" 2>&1 || return 1
  LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$tag"
}

if run=$(build_run . good) && [[ "$run" == *"linkage: 0 mismatches"* ]]; then
  echo "linkage (two units, one header): ok"
else
  echo "linkage: FAIL"; grep -v "pragma\|NV_SILENCE\|^ *\^\|^ *$\|warning" "$out/good.log" 2>/dev/null | head -5; fail=1
fi

# Mutant: the kernel adds 2 instead of 1 (in a scratch copy).
mut=$out/mut; mkdir -p "$mut"; cp unit_a.cu unit_b.cu kern.cuh "$mut/"
sed -i 's/b\[i\] = b\[i\] + 1;/b[i] = b[i] + 2;/' "$mut/kern.cuh"
if run=$(build_run "$mut" mut) && [[ "$run" == *"linkage: 0 mismatches"* ]]; then
  echo "mutant linkage: FAIL (not caught)"; fail=1
else
  echo "mutant linkage: caught"
fi
exit $fail
