#!/usr/bin/env bash
# The device half of the SYCL front end (scripts/sycl-rewrite.rb): the parallel_for kernel of vecadd.cpp (a SYCL program with
# buffers, accessors and parallel_for) is rewritten to an extern "C" device function, lowered to IR (Path B, goldens
# vecadd_device.cpp and vecadd_device.ir), emitted as SPIR-V (vecadd.spvasm), validated by spirv-val, and run on the Intel XPU
# over 50000 elements with the launcher of tests/gpu/spirv, and the SYCL source itself runs on the runtime. A mutant SYCL source (+ -> -) must fail; a 2-D range and a source
# with no parallel_for are refused with exit 3. Needs the Path B harness, the SPIRV-Tools binaries (SPIRV_TOOLS_BIN or PATH),
# OPENCL_INCLUDE and libOpenCL.so.1 and an OpenCL GPU; skips (exit 0) when one is missing. Step 5 runs the unchanged SYCL
# source on the host runtime (lib/sycl/include/sycl/sycl.hpp) with the SPIR-V in NFCXX_SYCL_SPV.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
tools=${SPIRV_TOOLS_BIN:-}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if [ -n "$tools" ]; then export PATH="$tools:$PATH"; fi
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || ! command -v spirv-as >/dev/null || ! command -v spirv-val >/dev/null \
   || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu sycl: needs the Path B harness, spirv-as, spirv-val, the OpenCL headers and libOpenCL.so.1"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mrb() { "$root/scripts/mrb" "$@"; }

# 1. The rewrite of the SYCL source matches its golden; the device source is lowered to IR (golden).
mrb "$root/scripts/sycl-rewrite.rb" vecadd.cpp > "$out/vecadd_device.cpp"
if diff -u vecadd_device.cpp "$out/vecadd_device.cpp"; then echo "rewrite vecadd: ok"; else echo "rewrite vecadd: FAIL"; fail=1; fi
(cd "$out" && "$root/scripts/pathb-dump" --ir --freestanding vecadd_device.cpp > vecadd_device.ir)
if diff -u vecadd_device.ir "$out/vecadd_device.ir"; then echo "IR vecadd: ok"; else echo "IR vecadd: FAIL"; fail=1; fi

# 2. The SPIR-V emitter lowers it to the golden assembly; it assembles and validates.
mrb "$root/scripts/pathb-spirv-emit.rb" "$out/vecadd_device.ir" > "$out/vecadd.spvasm"
if diff -u vecadd.spvasm "$out/vecadd.spvasm"; then echo "asm vecadd: ok"; else echo "asm vecadd: FAIL"; fail=1; fi
spirv-as --target-env spv1.1 "$out/vecadd.spvasm" -o "$out/vecadd.spv"
if spirv-val --target-env spv1.1 "$out/vecadd.spv"; then echo "validate vecadd: ok"; else echo "validate vecadd: FAIL"; fail=1; fi

# 3. The launcher runs the kernel on the GPU (the same signature as the vecAdd of tests/gpu/spirv).
gcc -O2 -Wall -I"$clinc" ../spirv/launch.c -o "$out/launch" -l:libOpenCL.so.1
set +e
run=$("$out/launch" "$out/vecadd.spv" __nfcxx_sycl_k0 2>&1); rc=$?
set -e
if [ $rc = 2 ] && grep -q "no OpenCL GPU" <<< "$run"; then
  echo "SKIP: gpu sycl: no OpenCL GPU device"; exit 0
fi
echo "$run"
if [ $rc = 0 ]; then echo "run vecadd: ok"; else echo "run vecadd: FAIL"; fail=1; fi

# 4. A mutant SYCL source (+ -> -) must fail the same run.
sed 's/ra\[i\] + rb\[i\]/ra[i] - rb[i]/' vecadd.cpp > "$out/mut.cpp"
mrb "$root/scripts/sycl-rewrite.rb" "$out/mut.cpp" > "$out/mut_device.cpp"
(cd "$out" && "$root/scripts/pathb-dump" --ir --freestanding mut_device.cpp > mut_device.ir)
mrb "$root/scripts/pathb-spirv-emit.rb" "$out/mut_device.ir" > "$out/mut.spvasm"
spirv-as --target-env spv1.1 "$out/mut.spvasm" -o "$out/mut.spv"
if "$out/launch" "$out/mut.spv" __nfcxx_sycl_k0 >/dev/null 2>&1; then
  echo "mutant vecadd: FAIL (not caught)"; fail=1
else
  echo "mutant vecadd: caught"
fi

# 5. The SYCL source itself (vecadd.cpp, unchanged) builds against the host runtime (lib/sycl/include) and runs: the runtime loads the
# SPIR-V named by NFCXX_SYCL_SPV and launches __nfcxx_sycl_k0 with the three accessors. The mutant SPIR-V must fail the host run.
g++ -std=c++17 -O2 -Wall -I"$root/lib/sycl/include" -I"$clinc" vecadd.cpp -o "$out/host" -l:libOpenCL.so.1
if NFCXX_SYCL_SPV="$out/vecadd.spv" "$out/host"; then echo "run sycl host: ok"; else echo "run sycl host: FAIL"; fail=1; fi
if NFCXX_SYCL_SPV="$out/mut.spv" "$out/host" >/dev/null 2>&1; then
  echo "mutant sycl host: FAIL (not caught)"; fail=1
else
  echo "mutant sycl host: caught"
fi

# 6. Constructs the rewrite does not lower are refused with exit 3.
for f in refuse_2d.cpp refuse_none.cpp; do
  rc=0; mrb "$root/scripts/sycl-rewrite.rb" "$f" > /dev/null 2>&1 || rc=$?
  if [ "$rc" = 3 ]; then echo "refused $f: ok"; else echo "refused $f: FAIL (exit $rc)"; fail=1; fi
done

exit $fail
