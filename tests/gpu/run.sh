#!/usr/bin/env bash
# GPU kernel test: the hand-written IR kernel (mul2.ir) is lowered to PTX by tools/pathb-ptx-emit,
# assembled by ptxas for sm_75, and launched through the CUDA runtime API (launch.c).
# The launcher uses the CUDA runtime API (cudart), not the driver API. Needs ptxas, cuda_runtime.h and libcudart
# (CUDA 12.8 or later, for cudaLibraryLoadData), and an NVIDIA GPU. Skips (exit 0) when one is missing.
# CUDA_HOME is the toolkit root holding bin/ptxas and lib64/libcudart.so (default /usr/local/cuda).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || exit 1
# The PTX emitter: the C++ tool (tools/pathb-ptx-emit).
emit_ptx() {
  [ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || return 1
  "$root/build/pathb-ptx-emit" --emit "$@"
}
arch=${GPU_ARCH:-sm_75}
cuda=${CUDA_HOME:-/usr/local/cuda}

ptxas=$cuda/bin/ptxas
inc=$cuda/include
if [ ! -x "$ptxas" ] || [ ! -f "$inc/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu: needs ptxas, cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
emit_ptx mul2.ir > "$out/mul2.ptx"
"$ptxas" -arch="$arch" "$out/mul2.ptx" -o "$out/mul2.cubin"
gcc -O2 -Wall -I"$inc" -L"$cuda/lib64" launch.c -o "$out/launch" -lcudart
"$out/launch" "$out/mul2.cubin"
