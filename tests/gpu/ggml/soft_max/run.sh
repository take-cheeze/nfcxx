#!/usr/bin/env bash
# The llama.cpp testbed for ggml-sycl's soft_max (ggml/src/ggml-sycl/softmax.cpp): F32, scale 1.0, without and with an F32
# mask, on two shapes (64x4x2x1 and 128x7x3x2; ne0 is the softmax dimension), with 64 guard slots past the output.
# soft_max_kernel.cpp holds the row kernel (the max and the sum by sub-group reductions and local memory with barriers) and
# its launch copied from softmax.cpp, built with scripts/sycl-build.sh for OpenCL and Level Zero, run on the Intel XPU, and
# every element checked against a double-precision host reference. A mutant (the row max is omitted) must produce wrong
# results: it is caught only when the run completes and reports mismatches (a build failure or a runtime abort is not a
# catch). Needs the OpenCL headers (OPENCL_INCLUDE), spirv-val on PATH and the Intel GPU runtime; skips (exit 0) when one
# is missing, and a backend whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
clinc=${OPENCL_INCLUDE:-}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu ggml soft_max: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"; exit 0
fi
export OPENCL_INCLUDE=$clinc
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
fail=0
checks=4

# run BACKEND SOURCE NAME: builds and runs one variant; prints the verdict.
run() {
  local b=$1 src=$2 name=$3
  if ! "$root/scripts/sycl-build.sh" --backend="$b" "$src" -o "$out/$name" > "$out/$name.build" 2>&1; then
    echo "soft_max $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | head -3; return 1
  fi
  local res rc n_ok
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: soft_max $b: no device"; return 2; fi
  n_ok=$(grep -c ': ok$' <<< "$res")
  if [ $rc = 0 ] && [ "$n_ok" = "$checks" ] && grep -q "checks: $checks, failed: 0" <<< "$res"; then
    echo "soft_max $b $name: ok, $n_ok of $checks checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "soft_max $b $name: FAIL (rc $rc, $n_ok of $checks ok)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# caught BACKEND NAME: the mutant binary's run completed (rc 0 or the check's 1) with a verdict of mismatches.
caught() {
  local b=$1 name=$2 res rc
  if [ ! -x "$out/$name" ]; then return 1; fi
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  [ $rc = 70 ] && return 1
  [ $rc = 1 ] && grep -q "checks: $checks, failed: [1-9]" <<< "$res"
}

for b in opencl level-zero; do
  cp soft_max_kernel.cpp "$out/$b.soft_max.cpp"
  rc=0; run $b "$out/$b.soft_max.cpp" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: the row max is not taken (the running max stays -inf), so exp overflows and the outputs are wrong
  sed 's/        max_val   = sycl::max(max_val, val);/        max_val   = max_val;/' soft_max_kernel.cpp > "$out/$b.mut.cpp"
  if cmp -s soft_max_kernel.cpp "$out/$b.mut.cpp"; then echo "mutant soft_max $b: FAIL (mutation did not apply)"; fail=1; continue; fi
  if "$root/scripts/sycl-build.sh" --backend="$b" "$out/$b.mut.cpp" -o "$out/$b.mut" > "$out/$b.mut.build" 2>&1 && caught $b "$b.mut"; then
    echo "mutant soft_max $b: caught"
  else
    echo "mutant soft_max $b: FAIL (not caught: build, abort or no wrong results)"; fail=1
  fi
done
exit $fail
