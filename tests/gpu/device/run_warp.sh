#!/usr/bin/env bash
# Warp intrinsics in a device kernel (warp.cpp): shuffles (xor, float), ballot, any and all, lowered by the emitter
# (WARP_SHUFFLES, WARP_VOTES), checked against the definitions on the host. Mutants (the first shuffle's mode, any
# as all) must fail. A shuffle with a non-constant mask is refused with exit 3.
# Needs the Path B harness, ptxas, cuda_runtime.h, libcudart and an NVIDIA GPU; skips (exit 0) when one is missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || exit 1
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu warp: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
K=_Z8warp_opsPKiPiPfPjS1_i

"$root/scripts/pathb-dump" --ir --freestanding warp.cpp > "$out/warp.ir"
if diff -u warp.ir "$out/warp.ir"; then echo "IR warp: ok"; else echo "IR warp: FAIL (golden differs)"; fail=1; fi

"$root/build/pathb-ptx-emit" --emit "$out/warp.ir" > "$out/warp.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/warp.ptx" -o "$out/warp.cubin"
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_warp.c -o "$out/launch" -lcudart
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/warp.cubin" "$K"; then
  echo "run warp: ok"
else
  echo "run warp: FAIL"; fail=1
fi

# Mutant 1: the first shuffle (the xor sum) becomes an up-shuffle.
sed '0,/shfl\.sync\.bfly\.b32/s//shfl.sync.up.b32/' "$out/warp.ptx" > "$out/mut1.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut1.ptx" -o "$out/mut1.cubin"
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/mut1.cubin" "$K" >/dev/null 2>&1; then
  echo "mutant warp shuffle: FAIL (not caught)"; fail=1
else
  echo "mutant warp shuffle: caught"
fi

# Mutant 2: vote.any becomes vote.all.
sed 's/vote\.sync\.any\.pred/vote.sync.all.pred/' "$out/warp.ptx" > "$out/mut2.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut2.ptx" -o "$out/mut2.cubin"
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/mut2.cubin" "$K" >/dev/null 2>&1; then
  echo "mutant vote any: FAIL (not caught)"; fail=1
else
  echo "mutant vote any: caught"
fi

# A shuffle whose mask is a variable (not the full-warp constant) is refused with exit 3.
cat > "$out/refuse_mask.cpp" <<'CPP'
extern "C" int __nfcxx_shfl_xor_sync_i(unsigned mask, int v, int lane);
void k(int *o, unsigned m) { o[0] = __nfcxx_shfl_xor_sync_i(m, 1, 2); }
CPP
rc=0; "$root/scripts/pathb-dump" --ir --freestanding "$out/refuse_mask.cpp" > "$out/refuse.ir" 2>/dev/null \
  && "$root/build/pathb-ptx-emit" --emit "$out/refuse.ir" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 3 ]; then echo "refused shuffle with a variable mask: ok"; else echo "refused shuffle with a variable mask: FAIL (exit $rc)"; fail=1; fi
exit $fail
