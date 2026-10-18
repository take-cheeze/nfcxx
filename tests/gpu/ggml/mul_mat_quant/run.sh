#!/usr/bin/env bash
# The real ggml-sycl dmmv.cpp (ggml/src/ggml-sycl/dmmv.cpp, unchanged), compiled as a TU of mul_mat_q8_real.cpp through
# scripts/sycl-build.sh for OpenCL and Level Zero, linked against libggml-sycl.so and libggml-base.so from the llama.cpp
# build, and run on the Intel XPU: the real ggml_sycl_op_dequantize_mul_mat_vec (the dmmv path of the ggml-sycl mul_mat
# dispatch) with a Q8_0 src0 and an F32 src1 vector, no reorder, on ncols 32, 256 and 1024 (rows 5, 64, 37), every output
# row checked against a double-precision dot product, and 64 guard slots past the output that must stay untouched. Two builds
# of the same source: F32 (float partial sums) and F16 (-DGGML_SYCL_F16, the libggml-sycl.so build: src1 converted to F16 and
# sycl::half2 partial sums; the half2 operators come from the lib/sycl-ggml shim). A mutant (a sed copy of the real file with
# the sub-group xor reduction stopped one step early, in the generic dequantize_mul_mat_vec) must produce wrong results in
# both builds: it is caught only by a run that completes with a checks line reporting mismatches on all three checks (a build
# failure, an abort or a stray line is not a catch). The link uses a version script that makes every symbol of the test
# executable local, so the test TU's own dpct helper copies do not interpose libggml-sycl's (see rope/rope_real.cpp).
# Env: GGML_BUILD (the build bin dir, libggml-sycl.so and libggml-base.so), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB
# (the oneAPI compiler lib dir: libiomp5, libsvml), SPIRV_TOOLS_BIN (the directory holding spirv-val, when it is not on PATH).
# Needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1; skips (exit 0) when one is missing, and a backend
# whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
ggml_root=$(cd "$ggml_src/../.." 2>/dev/null && pwd)   # the ggml/ dir (include/, src/ hold ggml.h and ggml-impl.h)
# the oneAPI runtime directories libsycl and libggml-sycl load (compiler, MKL, TBB, UMF); ONEAPI_LIB overrides the list
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/dmmv.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml mul_mat_quant: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/dmmv.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
# the Intel runtime libraries that libggml-sycl needs at run time
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# the mutant: a sed copy of the real dmmv.cpp with the first sub-group reduction (the generic dequantize_mul_mat_vec, the Q8_0
# kernel's) stopped one step early (mask > 1, so lane 0 never adds the lane 1 partial sum); dmmv.hpp, convert.hpp, dequantize.hpp
# and presets.hpp resolve from the real source dir through -I
sed '0,/for (int mask = mask_start; mask > 0; mask >>= 1)/s//for (int mask = mask_start; mask > 1; mask >>= 1)/' \
  "$ggml_src/dmmv.cpp" > "$out/mut/dmmv.cpp"
if cmp -s "$ggml_src/dmmv.cpp" "$out/mut/dmmv.cpp"; then echo "mutant mul_mat_quant: FAIL (mutation did not apply)"; exit 1; fi
fail=0 notrun=0

# run BACKEND SRCDIR NAME: builds and runs one variant (SRCDIR holds the dmmv.cpp to include); prints the verdict and keeps
# the run's output in $out/NAME.res. Returns 0 ok, 1 FAIL (the run failed its checks or exited nonzero), 2 SKIP (no device),
# 3 FAIL (build).
run() {
  local b=$1 srcdir=$2 name=$3 vflags=$4
  if ! "$root/scripts/sycl-build.sh" --backend="$b" --ndebug -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED $vflags \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_root/include" -I"$ggml_root/src" -I"$ggml_root" \
      "$root/tests/gpu/ggml/mul_mat_quant/mul_mat_q8_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "mul_mat_quant $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i -A2 "error\|refused" | head -4; return 3
  fi
  local res rc
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: mul_mat_quant $b: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: 3, failed: 0" <<< "$res"; then
    echo "mul_mat_quant $b $name: ok, 3 of 3 checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "mul_mat_quant $b $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# mutant_verdict FILE: classifies a mutant run's output. Returns 0 caught, 1 not caught, 2 NOT RUN.
# Caught needs a completed run (its "checks: 3, failed: K" line) in which every line is a device or check line, and all
# three checks report mismatches.
mutant_verdict() {
  local f=$1 bad
  grep -q "^checks: 3, failed: [0-9][0-9]*$" "$f" || return 2
  if grep -vqE '^(device: .*|checks: 3, failed: [0-9]+|dmmv Q8_0 ncols [0-9]+ rows [0-9]+: mismatches: [0-9]+ of [0-9]+, guard writes: [0-9]+ of 64, max err over sum\|wx\| [^:]*: (ok|FAIL))$' "$f"; then
    return 2
  fi
  bad=$(grep -cE '^dmmv Q8_0 ncols [0-9]+ rows [0-9]+: mismatches: [1-9][0-9]* of [0-9]+,' "$f")
  [ "$bad" = 3 ] && return 0
  return 1
}

for v in f32 f16; do
  vflags=""; [ $v = f16 ] && vflags=-DGGML_SYCL_F16
  for b in opencl level-zero; do
    rc=0; run "$b" "$ggml_src" "$b.$v" "$vflags" || rc=$?
    case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
    # the mutant: caught only by a run that completes with wrong results on all three checks
    rc=0; run "$b" "$out/mut" "$b.$v.mut" "$vflags" || rc=$?
    case $rc in
      2) continue ;;
      3) echo "mutant mul_mat_quant $b.$v: NOT RUN (build failed)"; notrun=$((notrun+1)) ;;
      *) mv=0; mutant_verdict "$out/$b.$v.mut.res" || mv=$?
         case $mv in
           0) echo "mutant mul_mat_quant $b.$v: caught" ;;
           1) echo "mutant mul_mat_quant $b.$v: FAIL (not caught)"; fail=1 ;;
           *) echo "mutant mul_mat_quant $b.$v: NOT RUN (the run did not complete with wrong results; see above)"; notrun=$((notrun+1)) ;;
         esac ;;
    esac
  done
done
[ $notrun = 0 ] || { echo "NOT RUN: $notrun run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
