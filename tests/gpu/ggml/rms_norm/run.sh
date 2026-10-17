#!/usr/bin/env bash
# The llama.cpp testbed for ggml-sycl's F32 rms_norm (ggml/src/ggml-sycl/norm.cpp), the first reduction op of the ladder:
# rms_norm_kernel.cpp holds the plain rms_norm_f32 kernel (its warp reduction through a sub-group), its launch and the
# stride setup, copied from norm.cpp, built with scripts/sycl-build.sh for OpenCL and Level Zero, run on the Intel XPU over
# two shapes (64x4x2x1 and 128x7x3x2, ne0 reduced, eps 1e-6), and every element checked against a double-precision host
# reference with 64 guard slots past the output. A mutant (eps omitted from the rsqrt) must be caught by a wrong result.
# A build or run failure is NOT RUN (exit 1), never a pass or a caught mutant. Needs the OpenCL headers (OPENCL_INCLUDE),
# spirv-val on PATH and the Intel GPU runtime; skips (exit 0) when one is missing, and a backend whose runtime reports no
# device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
clinc=${OPENCL_INCLUDE:-}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu ggml rms_norm: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"; exit 0
fi
export OPENCL_INCLUDE=$clinc
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
fail=0
checks=2

# run BACKEND SOURCE NAME: builds and runs one variant; prints the verdict. 0 ok, 1 not run or failed, 2 no device.
run() {
  local b=$1 src=$2 name=$3
  if ! "$root/scripts/sycl-build.sh" --backend="$b" "$src" -o "$out/$name" > "$out/$name.build" 2>&1; then
    echo "rms_norm $b $name: NOT RUN (build)"; grep -v -e prelinker -e pragma "$out/$name.build" | tail -3; return 1
  fi
  local res rc n_ok
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: rms_norm $b: no device"; return 2; fi
  n_ok=$(grep -c ': ok$' <<< "$res")
  if [ $rc = 0 ] && [ "$n_ok" = "$checks" ] && grep -q "checks: $checks, failed: 0" <<< "$res"; then
    echo "rms_norm $b $name: ok, $n_ok of $checks checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "rms_norm $b $name: FAIL (rc $rc, $n_ok of $checks ok)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

for b in opencl level-zero; do
  cp rms_norm_kernel.cpp "$out/$b.rms.cpp"
  rc=0; run $b "$out/$b.rms.cpp" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: eps is left out of the rsqrt, which the check must catch (the zero row gives 0/0 and the 1e-3 rows are off)
  sed 's/const float scale = sycl::rsqrt(mean + eps);/const float scale = sycl::rsqrt(mean);/' rms_norm_kernel.cpp > "$out/$b.mut.cpp"
  if cmp -s rms_norm_kernel.cpp "$out/$b.mut.cpp"; then echo "mutant rms_norm $b: NOT RUN (mutation did not apply)"; fail=1; continue; fi
  mres=$(run $b "$out/$b.mut.cpp" "$b.mut" 2>&1); mrc=$?
  if grep -q "NOT RUN" <<< "$mres"; then echo "mutant rms_norm $b: NOT RUN (build)"; fail=1
  elif [ $mrc = 0 ]; then echo "mutant rms_norm $b: FAIL (not caught)"; fail=1
  else echo "mutant rms_norm $b: caught"; fi
done
exit $fail
