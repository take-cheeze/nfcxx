#!/usr/bin/env bash
# Device helper functions (helper.cpp): calls from a kernel to a function of the module become PTX .func, and the
# kernels run on the GPU with the helpers' results. Lowers helper.cpp through the Path B front end, the emitter
# (tools/pathb-ptx-emit), ptxas for sm_75, and the CUDA runtime (launch_helper.c). Checks: the IR golden; the
# emitted kernels run with and without --kernel; a mutant is caught; struct-by-value and recursive helpers are
# refused (exit 3); --kernel with an unknown name exits 1. Needs the Path B harness, ptxas, cuda_runtime.h, libcudart
# and an NVIDIA GPU; skips (exit 0) when one is missing (CUDA_HOME, default /usr/local/cuda).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || make -s -C "$root/tools/pathb-ptx-emit" || exit 1
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu helper: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
emit() { "$root/build/pathb-ptx-emit" --emit "$@"; }
run_env() { LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$@"; }

# 1. The IR matches its golden.
"$root/scripts/pathb-dump" --ir --freestanding helper.cpp > "$out/helper.ir"
if diff -u helper.ir "$out/helper.ir"; then echo "IR helper: ok"; else echo "IR helper: FAIL"; fail=1; fi

# 2. Without flags: the callees become .func, the kernels run. With --kernel: the same result.
emit "$out/helper.ir" > "$out/helper.ptx"
emit --kernel=helper_kernel --kernel=helper_scale "$out/helper.ir" > "$out/helper_k.ptx"
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch_helper.c -o "$out/launch" -lcudart
for v in helper helper_k; do
  "$cuda/bin/ptxas" -arch=sm_75 "$out/$v.ptx" -o "$out/$v.cubin"
  if run_env "$out/launch" "$out/$v.cubin" > "$out/$v.log" 2>&1 && grep -q "helper_kernel: 0 mismatches, 0 guard writes" "$out/$v.log" \
     && grep -q "helper_scale: 0 mismatches, 0 guard writes" "$out/$v.log"; then
    echo "run $v: ok"
  else
    cat "$out/$v.log"; echo "run $v: FAIL"; fail=1
  fi
done
rc=0; "$root/scripts/pathb-dump" --ir --freestanding refuse_struct.cpp > "$out/refuse_struct.ir" 2>/dev/null && emit "$out/refuse_struct.ir" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ]; then echo "struct by value lowers: ok"; else echo "struct by value lowers: FAIL (exit $rc)"; fail=1; fi

# 3. A mutant (the helper adds 2, not 1) must be caught.
sed 's/add\.s32 %r3, %r2, 1;/add.s32 %r3, %r2, 2;/' "$out/helper.ptx" > "$out/mut.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut.ptx" -o "$out/mut.cubin"
if run_env "$out/launch" "$out/mut.cubin" >/dev/null 2>&1; then
  echo "mutant helper: FAIL (not caught)"; fail=1
else
  echo "mutant helper: caught"
fi

# 4. Refusals (exit 3): a recursive helper. A struct-by-value helper lowers (both emitters accept it), so it must not be refused.
for f in refuse_recursive; do
  rc=0; "$root/scripts/pathb-dump" --ir --freestanding "$f.cpp" > "$out/$f.ir" 2>/dev/null && emit "$out/$f.ir" > /dev/null 2>&1 || rc=$?
  if [ "$rc" = 3 ]; then echo "refused $f: ok"; else echo "refused $f: FAIL (exit $rc)"; fail=1; fi
done

# 5. --kernel with a name the IR does not have: exit 1.
rc=0; emit --kernel=no_such_kernel "$out/helper.ir" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 1 ]; then echo "unknown --kernel: ok"; else echo "unknown --kernel: FAIL (exit $rc)"; fail=1; fi

exit $fail
