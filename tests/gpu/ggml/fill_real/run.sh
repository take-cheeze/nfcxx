#!/usr/bin/env bash
# The real ggml-sycl fill.cpp (ggml/src/ggml-sycl/fill.cpp, unchanged), compiled as a TU of fill_real.cpp through
# scripts/sycl-build.sh for OpenCL and Level Zero, linked against libggml-sycl.so and libggml-base.so from the llama.cpp
# build, and run on the Intel XPU over 2069793 elements with 64 guard slots past the end. A mutant (fill value + 1; a sed
# copy of the real file) must fail. The link uses a version script that makes every symbol of the test executable local,
# so the test TU's own dpct helper copies do not interpose libggml-sycl's (see fill_real.cpp).
# Env: GGML_BUILD (the build bin dir, libggml-sycl.so and libggml-base.so), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB
# (the oneAPI compiler lib dir: libiomp5, libsvml). Needs spirv-val on PATH, the OpenCL headers (OPENCL_INCLUDE) and
# libOpenCL.so.1; skips (exit 0) when one is missing, and a backend whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH   # the directory holding spirv-val, when it is not on PATH
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
# the oneAPI runtime directories libsycl and libggml-sycl load (compiler, MKL, TBB, UMF); ONEAPI_LIB overrides the list
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/fill.cpp" ] \
  || [ ! -e "$oneapi_lib/libiomp5.so" ]; then
  echo "SKIP: gpu ggml fill_real: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/fill.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
# the Intel runtime libraries that libggml-sycl needs at run time
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
sed 's/dst\[i\] = value;/dst[i] = value + 1;/' "$ggml_src/fill.cpp" > "$out/mut/fill.cpp"
cp "$ggml_src/fill.hpp" "$ggml_src/common.hpp" "$out/mut/"
fail=0

# run BACKEND SRCDIR NAME: builds and runs one variant (SRCDIR holds the fill.cpp to include); prints the verdict.
run() {
  local b=$1 srcdir=$2 name=$3
  if ! "$root/scripts/sycl-build.sh" --backend="$b" -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$root/tests/gpu/ggml/fill_real/fill_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "fill_real $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i -A2 "error" | head -3; return 1
  fi
  local res rc
  res=$(timeout 120 "$out/$name" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: fill_real $b: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "mismatches: 0 of" <<< "$res" && grep -q "guard writes: 0 of" <<< "$res"; then
    echo "fill_real $b $name: ok ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "fill_real $b $name: FAIL (rc $rc)"; echo "$res" | tail -3; return 1
}

for b in opencl level-zero; do
  rc=0; run "$b" "$ggml_src" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: the fill writes value + 1, which the check must catch
  # caught means the mutant built and its run failed the check (a build failure or a pass is a failure of this test)
  mo=$(run "$b" "$out/mut" "$b.mut"); echo "$mo"
  if grep -q "FAIL (rc" <<< "$mo"; then echo "mutant fill_real $b: caught"; else echo "mutant fill_real $b: FAIL (not caught)"; fail=1; fi
done
exit $fail
