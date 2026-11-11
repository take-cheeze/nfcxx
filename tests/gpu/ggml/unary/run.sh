#!/usr/bin/env bash
# The llama.cpp testbed for ggml-sycl's unary element-wise ops (ggml/src/ggml-sycl/element_wise.cpp): neg, relu, silu and gelu,
# F32, each over the flat (contiguous) and the strided path, on two shapes (128x2x2x2 and 5x7x11x13), with 64 guard slots
# past the output. unary_kernel.cpp holds the op kernels and their launch code copied from element_wise.cpp, built with
# scripts/sycl-build.sh for OpenCL and Level Zero, run on the Intel XPU, and every element checked against a double-precision
# host reference. A mutant (relu uses min instead of max) must fail. Needs the OpenCL headers (OPENCL_INCLUDE), spirv-val on
# PATH and the Intel GPU runtime; skips (exit 0) when one is missing, and a backend whose runtime reports no device (exit 70)
# is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
clinc=${OPENCL_INCLUDE:-}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu ggml unary: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"; exit 0
fi
export OPENCL_INCLUDE=$clinc
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
fail=0
checks=16

# run BACKEND SOURCE NAME: builds and runs one variant; prints the verdict.
run() {
  local b=$1 src=$2 name=$3
  if ! "$root/scripts/sycl-build.sh" --backend="$b" "$src" -o "$out/$name" > "$out/$name.build" 2>&1; then
    echo "unary $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | head -3; return 1
  fi
  local res rc n_ok
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: unary $b: no device"; return 2; fi
  n_ok=$(grep -c ': ok$' <<< "$res")
  if [ $rc = 0 ] && [ "$n_ok" = "$checks" ] && grep -q "checks: $checks, failed: 0" <<< "$res"; then
    echo "unary $b $name: ok, $n_ok of $checks checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "unary $b $name: FAIL (rc $rc, $n_ok of $checks ok)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

for b in opencl level-zero; do
  cp unary_kernel.cpp "$out/$b.unary.cpp"
  rc=0; run $b "$out/$b.unary.cpp" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: relu takes the minimum instead of the maximum, which the check must catch
  sed 's/return sycl::fmax(x, static_cast<T>(0));/return sycl::fmin(x, static_cast<T>(0));/' unary_kernel.cpp > "$out/$b.mut.cpp"
  if cmp -s unary_kernel.cpp "$out/$b.mut.cpp"; then echo "mutant unary $b: FAIL (mutation did not apply)"; fail=1; continue; fi
  if run $b "$out/$b.mut.cpp" "$b.mut" >/dev/null 2>&1; then echo "mutant unary $b: FAIL (not caught)"; fail=1; else echo "mutant unary $b: caught"; fi
done
exit $fail
