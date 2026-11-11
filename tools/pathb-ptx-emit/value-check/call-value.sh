#!/usr/bin/env bash
# Value check of the device-intrinsic, warp, atomic and ptx-asm lowering (lower_call.cpp): each row of call-cases.tsv is
# lowered by build/pathb-ptx-emit --eval-arith, assembled by ptxas for sm_75, and run on the GPU; the same operation is
# written in CUDA (call-value.cu, compiled by nvcc) and run on the same inputs. Results and the scratch slots are compared
# bit for bit. Needs nvcc and ptxas (CUDA_HOME, default /usr/local/cuda), libcuda, and an NVIDIA GPU. Skips (exit 0) when
# one is missing.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$cuda/bin/nvcc" ] || [ ! -x "$cuda/bin/ptxas" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: call value check: needs nvcc, ptxas and an NVIDIA GPU"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
"$here/call-gen.sh" "$out" >/dev/null
"$cuda/bin/ptxas" -arch=sm_75 "$out/call-value.ptx" -o "$out/call-value.cubin"
"$cuda/bin/nvcc" -O2 -arch=sm_75 "$here/call-value.cu" -o "$out/call-value" -lcuda
"$out/call-value" "$out/call-value.cubin"
