#!/usr/bin/env bash
# contract.cpp (a*b - c*d and a*b + c on a million operand sets, every result compared bit for bit with the host's two-rounding
# values) built with scripts/sycl-build.sh for OpenCL and Level Zero and run on the Intel XPU. Checks the SPIR-V emitter's
# ContractionOff on the kernel: without it the device fuses some products into fused multiply-adds, and the run reports
# mismatches. Needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1; skips (exit 0) when one is missing,
# and a backend whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
clinc=${OPENCL_INCLUDE:-}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu contract: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"; exit 0
fi
export OPENCL_INCLUDE=$clinc
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0

# run BACKEND: builds contract.cpp for the backend and runs it; prints the verdict.
run() {
  local b=$1
  if ! "$root/scripts/sycl-build.sh" --backend="$b" contract.cpp -o "$out/$b" > "$out/$b.build" 2>&1; then
    echo "contract $b: FAIL (build)"; grep -v prelinker "$out/$b.build" | head -3; return 1
  fi
  local res rc
  res=$(timeout 300 "$out/$b" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: contract $b: no device"; return 0; fi
  if [ $rc = 0 ] && grep -q "mismatches: 0 of" <<< "$res"; then
    echo "contract $b: ok ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "contract $b: FAIL (run rc=$rc)"; echo "$res" | head -6; return 1
}

for b in level-zero opencl; do run $b || fail=1; done
exit $fail
