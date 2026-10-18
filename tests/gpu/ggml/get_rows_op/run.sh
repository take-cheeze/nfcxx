#!/usr/bin/env bash
# The real ggml-sycl getrows.cpp (ggml/src/ggml-sycl/getrows.cpp, unchanged), compiled as a TU of get_rows_op.cpp through
# scripts/sycl-build.sh for OpenCL, linked against libggml-sycl.so and libggml-base.so from the llama.cpp build, and run on
# the Intel XPU: the public ggml_sycl_op_get_rows for F32 and F16 tables with I32 indices, on shapes 64x5x2 (7 indices) and
# 128x9x2 (13 indices), every output element compared bit-exactly against the table, 64 guard slots past the output. A mutant
# (a sed copy of the real getrows.cpp in which the float copy reads the element before the one it writes) must produce wrong
# results: it is caught only by a run that completes with a checks line reporting mismatches on all four checks. Level Zero
# is not run here.
# Env: GGML_BUILD (the build bin dir, libggml-sycl.so and libggml-base.so), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB
# (the oneAPI runtime lib dirs), SPIRV_TOOLS_BIN (the directory holding spirv-val, when it is not on PATH). Needs spirv-val,
# the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1; skips (exit 0) when one is missing, and a run whose runtime
# reports no device (exit 70) is skipped.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/getrows.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml get_rows_op: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/getrows.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# the mutant: the float copy (dst_row[i00] = src0_row[i00]) reads the element before it; the expression is type-generic, so
# the quantized instances of the same switch still compile. getrows.hpp and common.hpp come with it.
sed 's/dst_row\[i00\] = src0_row\[i00\];/dst_row[i00] = src0_row[i00 ? i00 - 1 : 0];/' "$ggml_src/getrows.cpp" > "$out/mut/getrows.cpp"
if [ "$(grep -c 'src0_row\[i00 ? i00 - 1 : 0\];' "$out/mut/getrows.cpp")" != 1 ]; then echo "mutant get_rows_op: FAIL (mutation did not apply)"; exit 1; fi
cp "$ggml_src/getrows.hpp" "$ggml_src/common.hpp" "$out/mut/"
fail=0 notrun=0

# run SRCDIR NAME: builds and runs one variant (SRCDIR holds the getrows.cpp to include); prints the verdict and keeps the
# run's output in $out/NAME.res. Returns 0 ok, 1 FAIL (the run failed its checks or exited nonzero), 2 SKIP (no device),
# 3 FAIL (build).
run() {
  local srcdir=$1 name=$2
  if ! "$root/scripts/sycl-build.sh" --backend=opencl -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$root/tests/gpu/ggml/get_rows_op/get_rows_op.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "get_rows_op $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i -A2 "error\|refused" | head -4; return 3
  fi
  local res rc
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: get_rows_op: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: 4, failed: 0" <<< "$res"; then
    echo "get_rows_op $name: ok, 4 of 4 checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "get_rows_op $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# mutant_verdict FILE: caught needs a completed run (its "checks: 4, failed: K" line, and nothing else but the device and
# check lines) in which all four checks report mismatches. Returns 0 caught, 1 not caught, 2 NOT RUN.
mutant_verdict() {
  local f=$1 bad
  grep -q "^checks: 4, failed: [0-9][0-9]*$" "$f" || return 2
  if grep -vqE '^(device: .*|checks: 4, failed: [0-9]+|get_rows (F32|F16) [0-9x]+ idx [0-9]+: mismatches: [0-9]+ of [0-9]+, guard writes: [0-9]+ of 64: (ok|FAIL))$' "$f"; then
    return 2
  fi
  bad=$(grep -cE '^get_rows (F32|F16) [0-9x]+ idx [0-9]+: mismatches: [1-9][0-9]* of [0-9]+,' "$f")
  [ "$bad" = 4 ] && return 0
  return 1
}

rc=0; run "$ggml_src" opencl || rc=$?
case $rc in 0) ;; 2) exit 0 ;; *) fail=1 ;; esac
# the mutant: caught only by a run that completes with wrong results on all four checks
rc=0; run "$out/mut" opencl.mut || rc=$?
case $rc in
  2) exit 0 ;;
  3) echo "mutant get_rows_op opencl: NOT RUN (build failed)"; notrun=$((notrun+1)) ;;
  *) mv=0; mutant_verdict "$out/opencl.mut.res" || mv=$?
     case $mv in
       0) echo "mutant get_rows_op opencl: caught" ;;
       1) echo "mutant get_rows_op opencl: FAIL (not caught)"; fail=1 ;;
       *) echo "mutant get_rows_op opencl: NOT RUN (the run did not complete with wrong results; see above)"; notrun=$((notrun+1)) ;;
     esac ;;
esac
[ $notrun = 0 ] || { echo "NOT RUN: $notrun run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
