#!/usr/bin/env bash
# The ggml-sycl SUM_ROWS op (ggml_sycl_op_sum_rows, upstream ggml/src/ggml-sycl/ggml-sycl.cpp): sum_rows_real.cpp builds it as
# its own TU through scripts/sycl-build.sh for OpenCL, links libggml-sycl.so and libggml-base.so from the llama.cpp build, and
# runs it on the Intel XPU for three contiguous F32 shapes with 64 guard slots past the output. The upstream definitions are
# static or inline inside ggml-sycl.cpp (too large to compile as a TU), so sum_rows_upstream.cpp carries their text verbatim:
# this script first checks that copy against the upstream file. A mutant (a sed copy of sum_rows_upstream.cpp in which each
# row's sum is off by one) must be caught: a run that completes with a checks line reporting mismatches on every check.
# Env: GGML_BUILD (the build bin dir), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB (the oneAPI runtime lib dirs),
# SPIRV_TOOLS_BIN (the directory holding spirv-val, when it is not on PATH), OPENCL_INCLUDE (the OpenCL headers).
# Skips (exit 0) when one is missing, and a run whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
nchecks=3

if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/ggml-sycl.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml sum_rows: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/ggml-sycl.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# the copy must be the upstream text: the three definitions, extracted from ggml-sycl.cpp by their signature lines up to the
# closing brace at column 0, against the code lines of sum_rows_upstream.cpp (comments and blank lines ignored on both sides)
extract() { awk -v pat="$1" 'index($0,pat)==1 {on=1} on {print} on && /^}/ {on=0}' "$ggml_src/ggml-sycl.cpp"; }
upstream=$({ extract "static void k_sum_rows_f32("; extract "static void sum_rows_f32_sycl("; extract "inline void ggml_sycl_op_sum_rows("; } | grep -v '^$')
copy=$(grep -v '^//' "$here/sum_rows_upstream.cpp" | grep -v '^$')
if [ -z "$upstream" ] || [ "$upstream" != "$copy" ]; then
  echo "sum_rows: FAIL (sum_rows_upstream.cpp is not the upstream text of k_sum_rows_f32, sum_rows_f32_sycl and ggml_sycl_op_sum_rows)"; exit 1
fi

# the mutant: each row's sum is off by one, in the verbatim copy of k_sum_rows_f32 (a sed copy in $out/mut)
sed 's/        dst\[row\] = sum;/        dst[row] = sum + 1.0f;/' "$here/sum_rows_upstream.cpp" > "$out/mut/sum_rows_upstream.cpp"
if [ "$(grep -c 'sum + 1.0f;' "$out/mut/sum_rows_upstream.cpp")" != 1 ]; then echo "mutant sum_rows: FAIL (mutation did not apply)"; exit 1; fi
fail=0 notrun=0

# run SRCDIR NAME: builds sum_rows_real.cpp with sum_rows_upstream.cpp from SRCDIR and runs it. Returns 0 ok, 1 FAIL (checks
# failed or the run exited nonzero), 2 SKIP (no device), 3 FAIL (build). The run's output is kept in $out/NAME.res.
run() {
  local srcdir=$1 name=$2 res rc
  if ! "$root/scripts/sycl-build.sh" --backend=opencl --ndebug -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$here/sum_rows_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "sum_rows $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i "error\|refused\|undefined\|multiple" | head -6; return 3
  fi
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: sum_rows: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: $nchecks, failed: 0" <<< "$res"; then
    echo "sum_rows $name: ok, $nchecks of $nchecks checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "sum_rows $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# mutant_verdict FILE: 0 caught (a completed run, every check reports mismatches), 1 not caught, 2 NOT RUN (anything else)
mutant_verdict() {
  local f=$1 bad
  grep -q "^checks: $nchecks, failed: [0-9][0-9]*$" "$f" || return 2
  if grep -vqE "^(device: .*|checks: $nchecks, failed: [0-9]+|sum_rows F32 [0-9x]+ flat: mismatches: [0-9]+ of [0-9]+, guard writes: [0-9]+ of 64, max abs err .*: (ok|FAIL))\$" "$f"; then
    return 2
  fi
  bad=$(grep -cE "^sum_rows F32 [0-9x]+ flat: mismatches: [1-9][0-9]* of [0-9]+," "$f")
  [ "$bad" = "$nchecks" ] && return 0
  return 1
}

rc=0; run "$here" real || rc=$?
case $rc in
  0) ;;
  2) exit 0 ;;
  *) fail=1 ;;
esac
# the mutant: caught only by a run that completes with wrong results on every check
rc=0; run "$out/mut" mutant || rc=$?
case $rc in
  2) exit 0 ;;
  3) echo "mutant sum_rows: NOT RUN (build failed)"; notrun=$((notrun+1)) ;;
  *) mv=0; mutant_verdict "$out/mutant.res" || mv=$?
     case $mv in
       0) echo "mutant sum_rows: caught" ;;
       1) echo "mutant sum_rows: FAIL (not caught)"; fail=1 ;;
       *) echo "mutant sum_rows: NOT RUN (the run did not complete with wrong results; see above)"; notrun=$((notrun+1)) ;;
     esac ;;
esac
[ $notrun = 0 ] || { echo "NOT RUN: $notrun run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
