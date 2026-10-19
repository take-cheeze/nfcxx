#!/usr/bin/env bash
# Warp barrier (syncwarp.cpp): __syncwarp(mask) lowers to bar.warp.sync with the mask as its operand. The kernel
# writes a lane's index to shared memory, waits for its warp, and reads the next lane's value: 0 mismatches over
# four blocks of 32 lanes. A mutant that reads a different neighbour must fail, and the PTX must contain bar.warp.sync.
# Needs the Path B harness, ptxas, cuda_runtime.h, libcudart and an NVIDIA GPU; skips (exit 0) when one is missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || make -s -C "$root/tools/pathb-ptx-emit" || exit 1
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu syncwarp: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu"
kernel=_Z9warp_passPf

"$root/scripts/pathb-dump" --ir --freestanding syncwarp.cpp > "$out/syncwarp.ir"
"$root/build/pathb-ptx-emit" --emit "$out/syncwarp.ir" > "$out/syncwarp.ptx"
if grep -q "bar.warp.sync" "$out/syncwarp.ptx"; then echo "barrier lowered: ok"; else echo "barrier lowered: FAIL (no bar.warp.sync)"; fail=1; fi
"$cuda/bin/ptxas" -arch=sm_75 "$out/syncwarp.ptx" -o "$out/syncwarp.cubin"
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_syncwarp.c -o "$out/launch" -lcudart
if "$out/launch" "$out/syncwarp.cubin" "$kernel"; then echo "run syncwarp: ok"; else echo "run syncwarp: FAIL"; fail=1; fi

# mutant: the neighbour is two lanes away, so the expected values differ
sed 's/buf\[(t + 1) % 32\]/buf[(t + 2) % 32]/' syncwarp.cpp > "$out/mut.cpp"
"$root/scripts/pathb-dump" --ir --freestanding "$out/mut.cpp" > "$out/mut.ir"
"$root/build/pathb-ptx-emit" --emit "$out/mut.ir" > "$out/mut.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut.ptx" -o "$out/mut.cubin"
if "$out/launch" "$out/mut.cubin" "$kernel" >/dev/null 2>&1; then echo "mutant syncwarp: FAIL (not caught)"; fail=1; else echo "mutant syncwarp: caught"; fi

exit $fail
