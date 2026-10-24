#!/usr/bin/env bash
# The oneMKL subset of lib/sycl-ggml/oneapi/mkl.hpp (onemkl.cpp: gemm, gemm_batch in both forms, trsm_batch) on the Intel
# XPU through OpenCL and Level Zero, checked against a double-precision host reference. A mutant (both gemm loops skip
# their last term) must fail every gemm check. Needs spirv-val (SPIRV_TOOLS_BIN), the OpenCL headers and the nfcxx
# build; a backend whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
. "$root/scripts/oneapi-env.sh"
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
if ! command -v spirv-val >/dev/null || [ ! -f "${OPENCL_INCLUDE:-}/CL/cl.h" ]; then
  echo "SKIP: gpu ggml onemkl: needs spirv-val and the OpenCL headers (OPENCL_INCLUDE)"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
mkdir -p "$out/mut/oneapi"
sed -e 's/for (std::int64_t l = 0; l < k; l++) {/for (std::int64_t l = 0; l < k - 1; l++) {/' \
    -e 's/for (std::int64_t l = 0; l < gk; l++) {/for (std::int64_t l = 0; l < gk - 1; l++) {/' \
    "$root/lib/sycl-ggml/oneapi/mkl.hpp" > "$out/mut/oneapi/mkl.hpp"
grep -q 'l < k - 1' "$out/mut/oneapi/mkl.hpp" && grep -q 'l < gk - 1' "$out/mut/oneapi/mkl.hpp" \
  || { echo "onemkl: the mutant sed did not apply to both gemm loops"; exit 1; }

# run BACKEND INCDIR NAME: 0 ok, 1 FAIL, 2 SKIP
run() {
  local b=$1 inc=$2 name=$3 res rc=0
  if ! "$root/scripts/sycl-build.sh" --backend=$b -I"$inc" -I"$root/lib/sycl-ggml" onemkl.cpp -o "$out/$name" > "$out/$name.log" 2>&1; then
    echo "onemkl $name: FAIL (build)"; grep -v prelinker "$out/$name.log" | grep -i -A2 error | head -5; return 1
  fi
  res=$(timeout 300 "$out/$name" 2>&1) || rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: onemkl $b: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "failed: 0$" <<< "$res"; then echo "onemkl $name: ok ($(grep -m1 '^checks' <<< "$res"))"; return 0; fi
  echo "onemkl $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -8; return 1
}

for b in opencl level-zero; do
  rc=0; run $b "$root/lib/sycl-ggml" $b || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  rc=0; run $b "$out/mut" $b.mut > /dev/null || rc=$?
  # caught: the run completes and every gemm check (not the trsm ones) fails
  ngemm=$(grep -c '^gemm.*: FAIL$' "$out/$b.mut.res" 2>/dev/null)
  if [ $rc = 1 ] && [ "$ngemm" = 10 ]; then echo "mutant onemkl $b: caught (10 of 10 gemm checks)"; else echo "mutant onemkl $b: FAIL (rc $rc, $ngemm of 10 gemm checks failed)"; fail=1; fi
done
exit $fail
