#!/usr/bin/env bash
# SPIR-V text emitter (scripts/pathb-spirv-kernel-emit.rb): the vecAdd kernel of tests/gpu/device, lowered from the Path B IR to
# SPIR-V assembly, assembled by spirv-as, validated by spirv-val, and run on the Intel XPU through OpenCL (launch.c) over
# 50000 elements. Checks: the assembly matches its golden (vecadd.spvasm), a mutant (OpFAdd -> OpFSub) must fail the run,
# a construct the emitter does not lower (trap) is refused with exit 3, and the loop kernel (loop.ir) sums correctly.
# Needs the SPIRV-Tools binaries (spirv-as, spirv-val; SPIRV_TOOLS_BIN or PATH), the OpenCL headers and loader
# (OPENCL_INCLUDE, default /opt/intel/oneapi/compiler/2026.1/include; libOpenCL.so.1) and an OpenCL GPU. Skips (exit 0)
# when one is missing. SPIRV-Tools from nixpkgs: nix-build '<nixpkgs>' -A spirv-tools, then SPIRV_TOOLS_BIN=<out>/bin.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
tools=${SPIRV_TOOLS_BIN:-}
clinc=${OPENCL_INCLUDE:-}
if [ -n "$tools" ]; then export PATH="$tools:$PATH"; fi
if ! command -v spirv-as >/dev/null || ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] \
   || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu spirv: needs spirv-as, spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# 1. The emitted assembly matches its golden.
"$root/scripts/mrb" "$root/scripts/pathb-spirv-kernel-emit.rb" ../device/vecadd.ir > "$out/vecadd.spvasm"
if diff -u vecadd.spvasm "$out/vecadd.spvasm"; then echo "asm vecadd: ok"; else echo "asm vecadd: FAIL"; fail=1; fi

# 2. It assembles and validates (SPIR-V 1.1 is what the OpenCL drivers take here).
spirv-as --target-env spv1.1 "$out/vecadd.spvasm" -o "$out/vecadd.spv"
if spirv-val --target-env spv1.1 "$out/vecadd.spv"; then echo "validate vecadd: ok"; else echo "validate vecadd: FAIL"; fail=1; fi

# 3. The launcher runs it on the GPU; every element and the guard region are checked.
gcc -O2 -Wall -I"$clinc" launch.c -o "$out/launch" -l:libOpenCL.so.1
set +e
run=$("$out/launch" "$out/vecadd.spv" _Z6vecAddPfS_S_i 2>&1); rc=$?
set -e
if [ $rc = 2 ] && grep -q "no OpenCL GPU" <<< "$run"; then
  echo "SKIP: gpu spirv: no OpenCL GPU device"; exit 0
fi
echo "$run"
if [ $rc = 0 ]; then echo "run vecadd: ok"; else echo "run vecadd: FAIL"; fail=1; fi

# 4. A mutant (add -> sub) must fail the same run.
sed 's/OpFAdd/OpFSub/' "$out/vecadd.spvasm" > "$out/mut.spvasm"
spirv-as --target-env spv1.1 "$out/mut.spvasm" -o "$out/mut.spv"
if "$out/launch" "$out/mut.spv" _Z6vecAddPfS_S_i >/dev/null 2>&1; then
  echo "mutant vecadd: FAIL (not caught)"; fail=1
else
  echo "mutant vecadd: caught"
fi

# 5. The loop kernel (loop.ir: break, a set accumulator) emits to its golden, validates, and sums 0..9 on the GPU. The
# mutant turns the bound test into <= (sum 55): it must fail. (Not OpIAdd -> OpISub: the counter would never reach the break.)
"$root/scripts/mrb" "$root/scripts/pathb-spirv-kernel-emit.rb" loop.ir > "$out/loop.spvasm"
if diff -u loop.spvasm "$out/loop.spvasm"; then echo "asm loop: ok"; else echo "asm loop: FAIL"; fail=1; fi
spirv-as --target-env spv1.1 "$out/loop.spvasm" -o "$out/loop.spv"
if spirv-val --target-env spv1.1 "$out/loop.spv"; then echo "validate loop: ok"; else echo "validate loop: FAIL"; fail=1; fi
gcc -O2 -Wall -I"$clinc" loop_sum.c -o "$out/loop_sum" -l:libOpenCL.so.1
if "$out/loop_sum" "$out/loop.spv" >/dev/null; then echo "run loop: ok"; else echo "run loop: FAIL"; fail=1; fi
sed 's/OpSLessThan /OpSLessThanEqual /' "$out/loop.spvasm" > "$out/loop_mut.spvasm"
spirv-as --target-env spv1.1 "$out/loop_mut.spvasm" -o "$out/loop_mut.spv"
if "$out/loop_sum" "$out/loop_mut.spv" >/dev/null 2>&1; then echo "mutant loop: FAIL (not caught)"; fail=1; else echo "mutant loop: caught"; fi

# 6. A construct the emitter does not lower is refused with exit 3.
rc=0; "$root/scripts/mrb" "$root/scripts/pathb-spirv-kernel-emit.rb" refuse_trap.ir > /dev/null 2>&1 || rc=$?
if [ "$rc" = 3 ]; then echo "refused trap: ok"; else echo "refused trap: FAIL (exit $rc)"; fail=1; fi

exit $fail
