#!/usr/bin/env bash
# The F32 x F32 mat-mul call of ggml-sycl (ggml_sycl_op_mul_mat_sycl's column_major::gemm, ggml-sycl.cpp around line 3227),
# made with ggml's argument order against the real oneMKL 2026.1 gemm on the Intel XPU, for OpenCL and Level Zero. Shapes
# 17x13x9 and 64x64x64, checked against a double-precision host oracle at 1e-4 relative tolerance, with 64 guard slots past
# the dst tail. A mutant (one output element nudged after gemm; built with -DMUTANT_PERTURB) must fail its checks.
#
# The host TU is compiled by the real oneAPI compiler (icpx -fsycl, linked to libmkl_sycl_blas), not by nfcxx: nfcxx's host pass cannot
# instantiate sycl::queue from the real <sycl/sycl.hpp> (backend.hpp:131 "cast to type ... is not allowed", see
# docs/notes/ggml-sycl.md). The MKL gemm is the kernel under test; no kernel in this test is nfcxx-compiled.
#
# Env: ONEAPI_ROOT (default /opt/intel/oneapi). Skips (exit 0) when icpx is missing; a backend with no device exits 70 and
# is skipped with a SKIP line.
set -uo pipefail
cd "$(dirname "$0")"
oneapi=${ONEAPI_ROOT:-/opt/intel/oneapi}
icpx=$oneapi/compiler/2026.1/bin/icpx
if [ ! -x "$icpx" ] || [ ! -d "$oneapi/mkl/2026.1/include/oneapi/mkl" ]; then
  echo "SKIP: gpu ggml mul_mat_f32: needs icpx and the oneMKL 2026.1 headers under ONEAPI_ROOT"; exit 0
fi
# the oneAPI runtime libraries the built binary loads (compiler, MKL, TBB, UMF)
. "../../../../scripts/oneapi-env.sh"
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
src=mul_mat_f32_mkl.cpp
fail=0 notrun=0

# build NAME DEFINES...: compiles the harness with icpx -fsycl and the MKL link line; returns 0, or 3 on a build failure.
build() {
  local name=$1; shift
  if ! "$icpx" -std=c++17 -O2 -fsycl -I"$oneapi/mkl/2026.1/include" -L"$oneapi/mkl/2026.1/lib" "$@" "$src" \
      -lmkl_sycl_blas -lmkl_intel_lp64 -lmkl_sequential -lmkl_core -o "$out/$name" > "$out/$name.build" 2>&1; then
    echo "mul_mat_f32 $name: FAIL (build)"; grep -i -A2 "error" "$out/$name.build" | head -6; return 3
  fi
}

# run BACKEND NAME: runs one binary on one backend; prints the verdict. Returns 0 ok, 1 FAIL, 2 SKIP (no device).
run() {
  local b=$1 name=$2 sel res rc
  case $b in opencl) sel=opencl:gpu ;; level-zero) sel=level_zero:gpu ;; esac
  res=$(ONEAPI_DEVICE_SELECTOR=$sel timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.$b.res"
  if [ $rc = 70 ]; then echo "SKIP: mul_mat_f32 $name $b: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "^checks: 2, failed: 0$" <<< "$res"; then
    echo "mul_mat_f32 $name $b: ok, 2 of 2 checks ($(grep -m1 '^device:' <<< "$res"))"; return 0
  fi
  echo "mul_mat_f32 $name $b: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -8; return 1
}

build real || { notrun=$((notrun+1)); }
build mutant -DMUTANT_PERTURB || { notrun=$((notrun+1)); }
if [ $notrun = 0 ]; then
  for b in opencl level-zero; do
    rc=0; run "$b" real || rc=$?
    case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
    # the mutant: the output element nudged by 1e-2 on both shapes, so both checks must report mismatches
    rc=0; run "$b" mutant || rc=$?
    case $rc in
      0) echo "mutant mul_mat_f32 $b: NOT caught"; fail=1 ;;
      1) if grep -q "^checks: 2, failed: 2$" "$out/mutant.$b.res"; then echo "mutant mul_mat_f32 $b: caught"; else echo "mutant mul_mat_f32 $b: NOT RUN (no completed checks line)"; notrun=$((notrun+1)); fi ;;
      2) continue ;;
    esac
  done
fi
[ $notrun = 0 ] || { echo "NOT RUN: $notrun build or run did not complete; this is a failure, not a pass"; fail=1; }
exit $fail
