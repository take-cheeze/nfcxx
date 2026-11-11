#!/usr/bin/env bash
# Value check of the arithmetic lowering (lower_arith.cpp) against nvcc: each row of cases.tsv is lowered by
# build/pathb-ptx-emit --eval-arith, assembled by ptxas for sm_75, and run on the GPU against the same operator written
# in CUDA (value.cu, compiled by nvcc). Results are compared bit for bit at the result's width. Needs nvcc and ptxas
# (CUDA_HOME, default /usr/local/cuda), libcuda, and an NVIDIA GPU. Skips (exit 0) when one is missing.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$cuda/bin/nvcc" ] || [ ! -x "$cuda/bin/ptxas" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: value check: needs nvcc, ptxas and an NVIDIA GPU"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
"$here/gen.sh" "$out" >/dev/null
"$cuda/bin/ptxas" -arch=sm_75 "$out/value.ptx" -o "$out/value.cubin"
"$cuda/bin/nvcc" -O2 -arch=sm_75 "$here/value.cu" -o "$out/value" -lcuda
"$out/value" "$out/value.cubin"
