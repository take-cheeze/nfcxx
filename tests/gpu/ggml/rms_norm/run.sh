#!/usr/bin/env bash
# The real ggml-sycl norm.cpp (ggml/src/ggml-sycl/norm.cpp, unchanged), compiled as a TU of rms_norm_real.cpp through
# scripts/sycl-build.sh for OpenCL and Level Zero, linked against libggml-sycl.so and libggml-base.so from the llama.cpp
# build, and run on the Intel XPU for two shapes (64x4x2x1 and 128x7x3x2, ne0 reduced, eps 1e-6) with every element checked
# against a double-precision reference and 64 guard slots past the output. A mutant (eps left out of the rsqrt; a sed copy
# of the real file) must fail. The link uses a version script that makes every symbol of the test executable local (see
# rms_norm_real.cpp). Env: GGML_BUILD (the build bin dir, libggml-sycl.so and libggml-base.so), GGML_SRC (the ggml-sycl
# source dir), ONEAPI_LIB (the oneAPI runtime lib dirs, colon-separated), SPIRV_TOOLS_BIN (the directory holding spirv-val,
# when not on PATH), OPENCL_INCLUDE (the OpenCL headers). Skips (exit 0) when one is missing; a backend whose runtime reports
# no device (exit 70) is skipped; a build or run failure is NOT RUN and fails the test.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/norm.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml rms_norm: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/norm.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# the mutant: eps is left out of the rsqrt of the plain instance (the only rsqrt(mean + eps) in norm.cpp)
sed 's/const float scale = sycl::rsqrt(mean + eps);/const float scale = sycl::rsqrt(mean);/' "$ggml_src/norm.cpp" > "$out/mut/norm.cpp"
if cmp -s "$ggml_src/norm.cpp" "$out/mut/norm.cpp"; then echo "rms_norm: the mutant sed did not apply (norm.cpp changed?)"; exit 1; fi
cp "$ggml_src/norm.hpp" "$ggml_src/common.hpp" "$out/mut/"
fail=0

# run BACKEND SRCDIR NAME: builds rms_norm_real.cpp against the norm.cpp in SRCDIR and runs it. Returns 0 when both checks
# pass, 2 when the runtime reports no device, 1 otherwise (a build failure prints NOT RUN (build)).
run() {
  local b=$1 srcdir=$2 name=$3 res rc
  if ! "$root/scripts/sycl-build.sh" --backend="$b" --ndebug -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$root/tests/gpu/ggml/rms_norm/rms_norm_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "rms_norm $b $name: NOT RUN (build)"; grep -v -e prelinker -e pragma "$out/$name.build" | grep -i -A2 "error" | head -3; return 1
  fi
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: rms_norm $b: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: 2, failed: 0" <<< "$res" && [ "$(grep -c ': ok$' <<< "$res")" = 2 ]; then
    echo "rms_norm $b $name: ok, 2 of 2 checks ($(grep -m1 device: <<< "$res"))"; grep ': ok$' <<< "$res"; return 0
  fi
  echo "rms_norm $b $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -5
  return 1
}

for b in opencl level-zero; do
  rc=0; run "$b" "$ggml_src" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: eps is left out of the rsqrt, which the check must catch (the zero row gives 0/0 and the 1e-3 rows are off)
  mrc=0; mo=$(run "$b" "$out/mut" "$b.mut") || mrc=$?
  if grep -q "NOT RUN (build)" <<< "$mo"; then echo "mutant rms_norm $b: NOT RUN (build)"; fail=1; continue; fi
  if [ $mrc = 2 ]; then continue; fi
  if [ $mrc = 1 ] && grep -q "FAIL (rc" <<< "$mo"; then echo "mutant rms_norm $b: caught"; else echo "mutant rms_norm $b: FAIL (not caught)"; fail=1; fi
done
exit $fail
