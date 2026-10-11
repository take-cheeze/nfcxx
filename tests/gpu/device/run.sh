#!/usr/bin/env bash
# Device code from C++ source: vecadd.cpp (the vecAdd kernel of NVIDIA cuda-samples 0_Introduction/vectorAdd) goes
# through the Path B front end (scripts/pathb-dump --ir), the IR-to-PTX emitter (scripts/pathb-ptx-emit.rb), ptxas
# for sm_75, and the CUDA runtime (launch.c) on 50000 elements. Needs the Path B harness (scripts/setup-pathb.sh),
# ptxas, cuda_runtime.h, libcudart and an NVIDIA GPU; skips (exit 0) when one is missing (CUDA_HOME, default
# /usr/local/cuda).
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
kernel=_Z6vecAddPfS_S_i
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ ! -x "$cuda/bin/ptxas" ] || [ ! -f "$cuda/include/cuda_runtime.h" ] \
   || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: gpu device: needs the Path B harness, ptxas, cuda_runtime.h, libcudart and nvidia-smi"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# 1. The IR of the kernel matches its golden (the front end lowers the source the same way).
"$root/scripts/pathb-dump" --ir --freestanding vecadd.cpp > "$out/vecadd.ir"
if diff -u vecadd.ir "$out/vecadd.ir"; then echo "IR vecadd: ok"; else echo "IR vecadd: FAIL"; fail=1; fi

# 2. The emitter lowers it; ptxas assembles it; the runtime runs it and checks every element and the guard.
"$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" "$out/vecadd.ir" > "$out/vecadd.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/vecadd.ptx" -o "$out/vecadd.cubin"
gcc -O2 -Wall -I"$cuda/include" -L"$cuda/lib64" launch.c -o "$out/launch" -lcudart
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/vecadd.cubin" "$kernel"; then
  echo "run vecadd: ok"
else
  echo "run vecadd: FAIL"; fail=1
fi

# 3. A mutant (add -> sub) must fail the same run.
sed 's/add\.rn\.f32/sub.rn.f32/' "$out/vecadd.ptx" > "$out/mut.ptx"
"$cuda/bin/ptxas" -arch=sm_75 "$out/mut.ptx" -o "$out/mut.cubin"
if LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/launch" "$out/mut.cubin" "$kernel" >/dev/null 2>&1; then
  echo "mutant vecadd: FAIL (not caught)"; fail=1
else
  echo "mutant vecadd: caught"
fi

# 4. A call the emitter does not lower is refused with exit 3.
rc=0; "$root/scripts/pathb-dump" --ir --freestanding refuse_call.cpp > "$out/refuse.ir" 2>/dev/null \
  && "$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" "$out/refuse.ir" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 3 ]; then echo "refused call: ok"; else echo "refused call: FAIL (exit $rc)"; fail=1; fi

exit $fail
