#!/usr/bin/env bash
# The real ggml-sycl top-k radix kernel (ggml/src/ggml-sycl/topk-radix.cpp, ggml_sycl_top_k_radix, unchanged), compiled as a
# TU of top_k_real.cpp through scripts/sycl-build.sh for OpenCL, linked against libggml-sycl.so and libggml-base.so from the
# llama.cpp build, and run on the Intel XPU (F32, two shapes, k < row length in both; see top_k_real.cpp for the shapes, the
# oracle and the checks). A mutant (a sed copy of topk-radix.cpp in which every emitted index is off by one) must be caught:
# only a run that completes with wrong results on every check counts as caught.
# Env: GGML_BUILD (the build bin dir), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB (the oneAPI runtime lib dirs),
# SPIRV_TOOLS_BIN (the directory holding spirv-val, when it is not on PATH). Needs spirv-val, the OpenCL headers
# (OPENCL_INCLUDE) and libOpenCL.so.1; skips (exit 0) when one is missing, and a run whose runtime reports no device (exit
# 70) is skipped.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
nchecks=2

if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/topk-radix.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml top_k: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/topk-radix.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# the mutant: every emitted index is off by one. The file has four emit sites, each written "] = col;" (the single-group
# pass and the split pass, each with its main and pivot-equal emit); all four must change.
sed 's/\] = col;/] = col + 1;/' "$ggml_src/topk-radix.cpp" > "$out/mut/topk-radix.cpp"
[ "$(grep -c '\] = col + 1;' "$out/mut/topk-radix.cpp")" = 4 ] \
  || { echo "mutant top_k: FAIL (mutation did not apply to all four emit sites)"; exit 1; }
cp "$ggml_src/topk-radix.hpp" "$ggml_src/common.hpp" "$out/mut/"
fail=0 notrun=0

# run SRCDIR NAME: builds and runs one variant (SRCDIR holds the topk-radix.cpp to include); prints the verdict and keeps
# the run's output in $out/NAME.res. Returns 0 ok, 1 FAIL (the run failed its checks or exited nonzero), 2 SKIP (no
# device), 3 FAIL (build).
run() {
  local srcdir=$1 name=$2
  if ! "$root/scripts/sycl-build.sh" --backend=opencl -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$here/top_k_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "top_k $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i "error\|refused\|undefined\|multiple" | head -6; return 3
  fi
  local res rc
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: top_k: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: $nchecks, failed: 0" <<< "$res"; then
    echo "top_k $name: ok, $nchecks of $nchecks checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "top_k $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# mutant_verdict FILE: classifies a mutant run's output. Returns 0 caught, 1 not caught, 2 NOT RUN.
# Caught needs a completed run (its "checks: N, failed: K" line, and nothing else but the device and check lines) in which
# every check reports mismatches. Any other line or a missing checks line means the mutant did not run to a wrong result.
mutant_verdict() {
  local f=$1 bad
  grep -q "^checks: $nchecks, failed: [0-9][0-9]*$" "$f" || return 2
  if grep -vqE "^(device: .*|checks: $nchecks, failed: [0-9]+|TOP_K F32 [0-9x]+ k=[0-9]+ (ties|distinct): mismatches: [0-9]+ of [0-9]+, guard writes: [0-9]+ of 64: (ok|FAIL))\$" "$f"; then
    return 2
  fi
  bad=$(grep -cE "^TOP_K F32 [0-9x]+ k=[0-9]+ (ties|distinct): mismatches: [1-9][0-9]* of " "$f")
  [ "$bad" = "$nchecks" ] && return 0
  return 1
}

rc=0; run "$ggml_src" opencl || rc=$?
case $rc in
  0) ;;
  2) exit 0 ;;
  *) fail=1 ;;
esac
# the mutant: caught only by a run that completes with wrong results on every check
rc=0; run "$out/mut" opencl.mut || rc=$?
case $rc in
  2) exit 0 ;;
  3) echo "mutant top_k: NOT RUN (build failed)"; notrun=$((notrun+1)) ;;
  *) mv=0; mutant_verdict "$out/opencl.mut.res" || mv=$?
     case $mv in
       0) echo "mutant top_k: caught" ;;
       1) echo "mutant top_k: FAIL (not caught)"; fail=1 ;;
       *) echo "mutant top_k: NOT RUN (the run did not complete with wrong results; see above)"; notrun=$((notrun+1)) ;;
     esac ;;
esac
[ $notrun = 0 ] || { echo "NOT RUN: $notrun run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
