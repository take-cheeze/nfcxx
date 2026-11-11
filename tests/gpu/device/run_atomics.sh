#!/usr/bin/env bash
# Atomics in a device kernel (atomics.cpp): integer and float add, max, add through a computed address, and cas,
# lowered by the emitter (ATOMICS) and checked on the GPU. Mutants (the first integer add becomes a max; the float add
# becomes an integer add) must fail. Needs the Path B harness, ptxas, cuda_runtime.h, libcudart and an NVIDIA GPU;
# skips (exit 0) when one is missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || exit 1
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu atomics: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
K=_Z7atomicsPKiPiPfS1_S1_S1_S1_i

"$root/scripts/pathb-dump" --ir --freestanding atomics.cpp > "$out/atomics.ir"
if diff -u atomics.ir "$out/atomics.ir"; then echo "IR atomics: ok"; else echo "IR atomics: FAIL (golden differs)"; fail=1; fi

"$root/build/pathb-ptx-emit" --emit "$out/atomics.ir" > "$out/atomics.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/atomics.ptx" -o "$out/atomics.cubin"
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_atomics.c -o "$out/launch" -lcudart
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/atomics.cubin" "$K"; then
  echo "run atomics: ok"
else
  echo "run atomics: FAIL"; fail=1
fi

# Mutant 1: the first integer add (the total) becomes a max.
sed '0,/atom\.add\.s32/s//atom.max.s32/' "$out/atomics.ptx" > "$out/mut1.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut1.ptx" -o "$out/mut1.cubin"
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/mut1.cubin" "$K" >/dev/null 2>&1; then
  echo "mutant atomic total: FAIL (not caught)"; fail=1
else
  echo "mutant atomic total: caught"
fi

# Mutant 2: the float add is dropped (the float sum stays zero).
sed '/atom\.add\.f32/d' "$out/atomics.ptx" > "$out/mut2.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut2.ptx" -o "$out/mut2.cubin"
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/mut2.cubin" "$K" >/dev/null 2>&1; then
  echo "mutant float atomic: FAIL (not caught)"; fail=1
else
  echo "mutant float atomic: caught"
fi
exit $fail
