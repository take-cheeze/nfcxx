#!/usr/bin/env bash
# Driver for the per-op directories under tests/gpu/ggml/binary/: bin_run.sh OP runs the real ggml-sycl binbcast.cpp entry
# point of OP (ggml_sycl_OP: add, sub, mul, div), unchanged, compiled as a TU of bin_real.cpp through scripts/sycl-build.sh
# for OpenCL, linked against libggml-sycl.so and libggml-base.so from the llama.cpp build, and run on the Intel XPU (F32,
# contiguous; a same-shape case and a broadcast case). A mutant (a copy of binbcast.hpp in which the op's one return line
# is off by one) must produce wrong results: it is caught only by a run that completes with a checks line reporting
# mismatches on every check. See bin_real.cpp for the checks and the reference.
# Env: GGML_BUILD (the build bin dir), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB (the oneAPI runtime lib dirs),
# SPIRV_TOOLS_BIN (the directory holding spirv-val, when it is not on PATH). Needs spirv-val, the OpenCL headers
# (OPENCL_INCLUDE) and libOpenCL.so.1; skips (exit 0) when one is missing, and a run whose runtime reports no device (exit
# 70) is skipped.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
op=${1:?usage: bin_run.sh OP}
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}

# The per-op table: the reference id (bin_real.cpp's ref()), the entry point, and the input ranges [lo, hi) for src0 and src1.
# div takes its divisor (src1) away from zero.
case $op in
  add) id=0; call=ggml_sycl_add; lo0=-4.0; hi0=4.0; lo1=-4.0; hi1=4.0 ;;
  sub) id=1; call=ggml_sycl_sub; lo0=-4.0; hi0=4.0; lo1=-4.0; hi1=4.0 ;;
  mul) id=2; call=ggml_sycl_mul; lo0=-4.0; hi0=4.0; lo1=-4.0; hi1=4.0 ;;
  div) id=3; call=ggml_sycl_div; lo0=-4.0; hi0=4.0; lo1=0.5;  hi1=4.0 ;;
  *) echo "bin_run.sh: no table entry for $op"; exit 2 ;;
esac
nchecks=2

if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/binbcast.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml binary $op: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/binbcast.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# the mutant: the op's return line in binbcast.hpp (op_$op) is off by one. The copy of binbcast.hpp is the one binbcast.cpp
# includes (the mutant dir comes first on -I and the include is resolved from the including file's directory).
case $op in
  add) old='return a + b;'; new='return a + b + 1.0f;' ;;
  sub) old='return a - b;'; new='return a - b + 1.0f;' ;;
  mul) old='return a \* b;'; new='return a * b + 1.0f;' ;;
  div) old='return a / b;'; new='return a / b + 1.0f;' ;;
esac
cp "$ggml_src/binbcast.cpp" "$ggml_src/binbcast.hpp" "$ggml_src/common.hpp" "$out/mut/"
sed "s|$old|$new|" "$ggml_src/binbcast.hpp" > "$out/mut/binbcast.hpp"
if [ "$(grep -cF "$new" "$out/mut/binbcast.hpp")" != 1 ] || cmp -s "$ggml_src/binbcast.hpp" "$out/mut/binbcast.hpp"; then
  echo "mutant binary $op: FAIL (mutation did not apply to op_$op in binbcast.hpp)"; exit 1
fi
fail=0 notrun=0

# run SRCDIR NAME: builds and runs one variant (SRCDIR holds the binbcast.cpp/.hpp to include); prints the verdict and
# keeps the run's output in $out/NAME.res. Returns 0 ok, 1 FAIL (checks or exit status), 2 SKIP (no device), 3 FAIL (build).
run() {
  local srcdir=$1 name=$2
  if ! "$root/scripts/sycl-build.sh" --backend=opencl -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -DBIN_ID="$id" -DBIN_OPNAME="$op" -DBIN_CALL="$call" -DBIN_LO0="$lo0" -DBIN_HI0="$hi0" -DBIN_LO1="$lo1" -DBIN_HI1="$hi1" \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$here/bin_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "binary $op $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i "error\|refused\|undefined\|multiple" | head -6; return 3
  fi
  local res rc
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: binary $op: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: $nchecks, failed: 0" <<< "$res"; then
    echo "binary $op $name: ok, $nchecks of $nchecks checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "binary $op $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# mutant_verdict FILE: 0 caught, 1 not caught, 2 NOT RUN. Caught needs a completed run (its checks line, and nothing but the
# device and check lines) in which every check reports mismatches.
mutant_verdict() {
  local f=$1 bad
  grep -q "^checks: $nchecks, failed: [0-9][0-9]*$" "$f" || return 2
  if grep -vqE "^(device: .*|checks: $nchecks, failed: [0-9]+|$op F32 [0-9x]+ src1 [0-9x]+ (same|bcast): mismatches: [0-9]+ of [0-9]+, guard writes: [0-9]+ of 64, max abs err .*: (ok|FAIL))\$" "$f"; then
    return 2
  fi
  bad=$(grep -cE "^$op F32 [0-9x]+ src1 [0-9x]+ (same|bcast): mismatches: [1-9][0-9]* of [0-9]+," "$f")
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
  3) echo "mutant binary $op: NOT RUN (build failed)"; notrun=$((notrun+1)) ;;
  *) mv=0; mutant_verdict "$out/opencl.mut.res" || mv=$?
     case $mv in
       0) echo "mutant binary $op: caught" ;;
       1) echo "mutant binary $op: FAIL (not caught)"; fail=1 ;;
       *) echo "mutant binary $op: NOT RUN (the run did not complete with wrong results; see above)"; notrun=$((notrun+1)) ;;
     esac ;;
esac
[ $notrun = 0 ] || { echo "NOT RUN: $notrun run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
