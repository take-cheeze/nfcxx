#!/usr/bin/env bash
# Device memory checks: a pointer read checked for null (nonnull.cpp: a valid pointer gives the right results, a null
# pointer traps the kernel) and block-shared memory with a barrier (shared.cpp: a block-level reversal through a
# file-scope static array, which the emitter lowers to .shared, with __nfcxx_syncthreads as bar.sync 0).
# Needs the Path B harness, ptxas, cuda_runtime.h, libcudart and an NVIDIA GPU; skips (exit 0) when one is missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || exit 1
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu memory: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu"
lower() { # lower SRC.cpp OUT: front end, emitter, ptxas; OUT.ptx and OUT.cubin
  "$root/scripts/pathb-dump" --ir --freestanding "$1" > "$2.ir" \
    && "$root/build/pathb-ptx-emit" --emit "$2.ir" > "$2.ptx" \
    && "$cuda/bin/ptxas" -arch=sm_75 "$2.ptx" -o "$2.cubin"
}

gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_nonnull.c -o "$out/launch_nonnull" -lcudart
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_shared.c -o "$out/launch_shared" -lcudart

# 1. nonnull: the golden IR has the check; the valid pointer gives 0 mismatches; the null pointer traps.
lower nonnull.cpp "$out/nonnull"
if diff -u nonnull.ir "$out/nonnull.ir" >/dev/null && grep -q "setp.eq.u64.*, 0;" "$out/nonnull.ptx" && grep -q "@%p0 trap;" "$out/nonnull.ptx"; then
  echo "nonnull lowering: ok"
else
  echo "nonnull lowering: FAIL"; fail=1
fi
k=_Z13load_plus_onePKiPi
if "$out/launch_nonnull" "$out/nonnull.cubin" $k ok; then echo "run nonnull ok: ok"; else echo "run nonnull ok: FAIL"; fail=1; fi
if "$out/launch_nonnull" "$out/nonnull.cubin" $k null; then echo "run nonnull null: ok"; else echo "run nonnull null: FAIL"; fail=1; fi

# 2. shared memory: the .shared declaration and the barrier are in the PTX; the reversal gives 0 mismatches.
lower shared.cpp "$out/shared"
if grep -q "^.shared .align 4 .b8 tile\[512\];" "$out/shared.ptx" && grep -q "bar.sync 0;" "$out/shared.ptx"; then
  echo "shared lowering: ok"
else
  echo "shared lowering: FAIL"; fail=1
fi
k=_Z13reverse_blockPKfPf
if "$out/launch_shared" "$out/shared.cubin" $k; then echo "run shared: ok"; else echo "run shared: FAIL"; fail=1; fi

# 3. mutant: the in-bounds index (tile[t] for tile[127 - t]) must fail the same run.
sed 's/out\[g\] = tile\[127 - t\];/out[g] = tile[t];/' shared.cpp > "$out/mut_index.cpp"
lower "$out/mut_index.cpp" "$out/mut_index"
if "$out/launch_shared" "$out/mut_index.cubin" $k >/dev/null 2>&1; then
  echo "mutant shared index: FAIL (not caught)"; fail=1
else
  echo "mutant shared index: caught"
fi

exit $fail
