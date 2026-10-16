#!/usr/bin/env bash
# GPU kernel test: the hand-written IR kernel (mul2.ir) is lowered to PTX by scripts/pathb-ptx-emit.rb,
# assembled by ptxas for sm_75, and launched through the CUDA runtime API (launch.c).
# The launcher uses the CUDA runtime API (cudart), not the driver API. Needs ptxas, cuda_runtime.h and libcudart
# (CUDA 12.8 or later, for cudaLibraryLoadData), and an NVIDIA GPU. Skips (exit 0) when one is missing.
# CUDA_HOME is the toolkit root holding bin/ptxas and lib64/libcudart.so (default /usr/local/cuda).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
arch=${GPU_ARCH:-sm_75}
cuda=${CUDA_HOME:-/usr/local/cuda}

ptxas=$cuda/bin/ptxas
inc=$cuda/include
if [ ! -x "$ptxas" ] || [ ! -f "$inc/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu: needs ptxas, cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
"$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" mul2.ir > "$out/mul2.ptx"
"$ptxas" -arch="$arch" "$out/mul2.ptx" -o "$out/mul2.cubin"
gcc -O2 -Wall -I"$inc" -L"$cuda/lib64" launch.c -o "$out/launch" -lcudart
"$out/launch" "$out/mul2.cubin"

# Reachability: only the functions the kernel reaches are lowered. The helper _Z5twicei is emitted, the dead function
# _Z6dead_fni (whose body the emitter refuses) is not, and the kernel's result is exact. The mutant (no helper) must be
# refused: a live function that is dropped cannot be called.
"$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" --kernel=mul2 reach.ir > "$out/reach.ptx"
grep -q "_Z5twicei" "$out/reach.ptx"
if grep -q "_Z6dead_fni" "$out/reach.ptx"; then echo "FAIL reach: the dead function was emitted"; exit 1; fi
"$ptxas" -arch="$arch" "$out/reach.ptx" -o "$out/reach.cubin"
"$out/launch" "$out/reach.cubin"
if "$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" --kernel=mul2 reach_mutant.ir > /dev/null 2>&1; then
  echo "FAIL reach_mutant: the kernel without its helper was emitted"; exit 1
fi
echo "reach: helper emitted, dead function not, mutant refused"
