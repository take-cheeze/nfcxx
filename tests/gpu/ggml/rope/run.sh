#!/usr/bin/env bash
# The real ggml-sycl rope.cpp (ggml/src/ggml-sycl/rope.cpp, unchanged), compiled as a TU of rope_real.cpp through
# scripts/sycl-build.sh for OpenCL and Level Zero, linked against libggml-sycl.so and libggml-base.so from the llama.cpp
# build, and run on the Intel XPU: the real ggml_sycl_rope in norm mode (not NEOX, mrope or vision), F32 and F16 inputs with
# the same F32 or F16 output, on shapes 64x4x2x1 and 128x7x3x2 (ne0 is the head dimension), with the full head dimension
# and the first half rotated, every element checked against a double-precision rotary embedding at 1e-4 (F32) or 2e-3 (F16)
# relative tolerance, and 64 guard slots past the output that must stay untouched. A mutant (a sed copy of the real file
# with the first rotated output of rope_norm negated in its sine term) must produce wrong results: it is caught only by a
# run that completes with a checks line reporting mismatches on all eight checks (a build failure, an abort or a stray line
# is not a catch). The link uses a version script that makes every symbol of the test executable local, so the test TU's
# own dpct helper copies do not interpose libggml-sycl's (see fill_real/fill_real.cpp).
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
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/rope.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml rope_real: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/rope.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
# the Intel runtime libraries that libggml-sycl needs at run time
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# the mutant: a sed copy of the real rope.cpp with the first rotated output of rope_norm negated (x0 cos + x1 sin); rope.hpp,
# convert.hpp and common.hpp resolve from the real source dir through -I
sed 's/store_coaelsced(x0 \* cos_theta - x1 \* sin_theta,/store_coaelsced(x0 * cos_theta + x1 * sin_theta,/' "$ggml_src/rope.cpp" > "$out/mut/rope.cpp"
if cmp -s "$ggml_src/rope.cpp" "$out/mut/rope.cpp"; then echo "mutant rope_real: FAIL (mutation did not apply)"; exit 1; fi
fail=0 notrun=0

# run BACKEND SRCDIR NAME: builds and runs one variant (SRCDIR holds the rope.cpp to include); prints the verdict and keeps
# the run's output in $out/NAME.res. Returns 0 ok, 1 FAIL (the run failed its checks or exited nonzero), 2 SKIP (no device),
# 3 FAIL (build).
run() {
  local b=$1 srcdir=$2 name=$3
  if ! "$root/scripts/sycl-build.sh" --backend="$b" -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$root/tests/gpu/ggml/rope/rope_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "rope_real $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i -A2 "error\|refused" | head -4; return 3
  fi
  local res rc
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: rope_real $b: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: 8, failed: 0" <<< "$res"; then
    echo "rope_real $b $name: ok, 8 of 8 checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "rope_real $b $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# mutant_verdict FILE: classifies a mutant run's output. Returns 0 caught, 1 not caught, 2 NOT RUN.
# Caught needs a completed run (its "checks: 8, failed: K" line) in which every line is a device or check line, and all
# eight checks report mismatches (the mutant touches every rotated output). Any other line (an error, an abort) or a
# missing checks line means the mutant did not run to a wrong result.
mutant_verdict() {
  local f=$1 bad
  grep -q "^checks: 8, failed: [0-9][0-9]*$" "$f" || return 2
  if grep -vqE '^(device: .*|checks: 8, failed: [0-9]+|rope (F32|F16) (64x4x2x1|128x7x3x2) (full|partial): mismatches: [0-9]+ of [0-9]+, guard writes: [0-9]+ of 64, max abs err .*: (ok|FAIL))$' "$f"; then
    return 2
  fi
  bad=$(grep -cE '^rope (F32|F16) [0-9x]+ (full|partial): mismatches: [1-9][0-9]* of [0-9]+,' "$f")
  [ "$bad" = 8 ] && return 0
  return 1
}

for b in opencl level-zero; do
  rc=0; run "$b" "$ggml_src" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: caught only by a run that completes with wrong results on all eight checks
  rc=0; run "$b" "$out/mut" "$b.mut" || rc=$?
  case $rc in
    2) continue ;;
    3) echo "mutant rope_real $b: NOT RUN (build failed)"; notrun=$((notrun+1)) ;;
    *) mv=0; mutant_verdict "$out/$b.mut.res" || mv=$?
       case $mv in
         0) echo "mutant rope_real $b: caught" ;;
         1) echo "mutant rope_real $b: FAIL (not caught)"; fail=1 ;;
         *) echo "mutant rope_real $b: NOT RUN (the run did not complete with wrong results; see above)"; notrun=$((notrun+1)) ;;
       esac ;;
  esac
done
[ $notrun = 0 ] || { echo "NOT RUN: $notrun run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
