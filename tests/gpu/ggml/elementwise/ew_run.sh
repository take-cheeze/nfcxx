#!/usr/bin/env bash
# Driver for the per-op directories under tests/gpu/ggml/elementwise/: ew_run.sh OP runs the real ggml-sycl element_wise.cpp
# entry point of OP (ggml_sycl_OP), unchanged, compiled as a TU of ew_real.cpp through scripts/sycl-build.sh for OpenCL,
# linked against libggml-sycl.so and libggml-base.so from the llama.cpp build, and run on the Intel XPU (F32, flat and
# strided where the upstream launcher supports strided input, two shapes, 64 guard slots). A mutant (a sed-style copy of the
# real element_wise.cpp in which the op's returned value is off by one) must produce wrong results: it is caught only by a run
# that completes with a checks line reporting mismatches on every check. See ew_real.cpp for the checks and the reference.
# Env: GGML_BUILD (the build bin dir), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB (the oneAPI runtime lib dirs),
# SPIRV_TOOLS_BIN (the directory holding spirv-val, when it is not on PATH). Needs spirv-val, the OpenCL headers
# (OPENCL_INCLUDE) and libOpenCL.so.1; skips (exit 0) when one is missing, and a run whose runtime reports no device (exit
# 70) is skipped.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
op=${1:?usage: ew_run.sh OP}
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}

# The per-op table: the reference id (ew_real.cpp's ref()), the entry point, the input range, and the two op_params.
case $op in
  sqrt)        id=0;  call=ggml_sycl_sqrt;        lo=0.0;  hi=4.0; p0=0;    p1=0 ;;
  sqr)         id=1;  call=ggml_sycl_sqr;         lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  clamp)       id=2;  call=ggml_sycl_clamp;       lo=-4.0; hi=4.0; p0=-1.5; p1=2.0 ;;
  sin)         id=3;  call=ggml_sycl_sin;         lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  cos)         id=4;  call=ggml_sycl_cos;         lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  log)         id=5;  call=ggml_sycl_log;         lo=0.05; hi=4.0; p0=0;    p1=0 ;;
  exp)         id=6;  call=ggml_sycl_exp;         lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  expm1)       id=7;  call=ggml_sycl_expm1;       lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  tanh)        id=8;  call=ggml_sycl_tanh;        lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  sigmoid)     id=9;  call=ggml_sycl_sigmoid;     lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  abs)         id=10; call=ggml_sycl_abs;         lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  sgn)         id=11; call=ggml_sycl_sgn;         lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  step)        id=12; call=ggml_sycl_step;        lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  hardsigmoid) id=13; call=ggml_sycl_hardsigmoid; lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  hardswish)   id=14; call=ggml_sycl_hardswish;   lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  softplus)    id=15; call=ggml_sycl_softplus;    lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  leaky_relu)  id=16; call=ggml_sycl_leaky_relu;  lo=-4.0; hi=4.0; p0=0.1;  p1=0 ;;
  elu)         id=17; call=ggml_sycl_elu;         lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  gelu_quick)  id=18; call=ggml_sycl_gelu_quick;  lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  gelu_erf)    id=19; call=ggml_sycl_gelu_erf;    lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  floor)       id=20; call=ggml_sycl_floor;       lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  ceil)        id=21; call=ggml_sycl_ceil;        lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  round)       id=22; call=ggml_sycl_round;       lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  trunc)       id=23; call=ggml_sycl_trunc;       lo=-4.0; hi=4.0; p0=0;    p1=0 ;;
  *) echo "ew_run.sh: no table entry for $op"; exit 2 ;;
esac
# the ops whose upstream launcher is dispatch_ggml_sycl_op_unary (element_wise.cpp) index the source flat: flat views only
flat_only=0
case $op in sqrt|sqr|clamp|sin|cos|log|leaky_relu) flat_only=1 ;; esac
if [ $flat_only = 1 ]; then nchecks=2; layouts="-DEW_FLAT_ONLY=1"; else nchecks=4; layouts=""; fi

if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/element_wise.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml elementwise $op: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/element_wise.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'find "$out" -mindepth 1 -delete; rmdir "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# the mutant: the op's returned value is off by one, in the real element_wise.cpp. Two shapes of the op in the file:
# (a) a function static __dpct_inline__ T op_<op>(...): its last return line is wrapped as (EXPR) + 1 (the F32 path is the last
#     return of these functions; the bf16 branch comes first);
# (b) otherwise the lambda in static inline void ggml_sycl_op_<op>(...) whose line is return op_<op>(x); becomes
#     return op_<op>(x) + 1 (typed by decltype(x)).
if [ "$op" = clamp ]; then
  # the clamp launcher calls the kernel clamp(), not op_clamp: below min it returns max (type-generic, no arithmetic)
  sed 's/x\[i\] < static_cast<T>(min) ? static_cast<T>(min) :/x[i] < static_cast<T>(min) ? static_cast<T>(max) :/' "$ggml_src/element_wise.cpp" > "$out/mut/element_wise.cpp"
  [ "$(grep -c 'x\[i\] < static_cast<T>(min) ? static_cast<T>(max) :' "$out/mut/element_wise.cpp")" = 1 ] \
    || { echo "mutant elementwise clamp: FAIL (mutation did not apply to clamp())"; exit 1; }
else
awk -v fn="op_$op" -v lam="ggml_sycl_op_$op(" '
  { lines[NR] = $0 }
  !in_fn && !in_lam && index($0, "static __dpct_inline__ T " fn "(") == 1 { in_fn = 1; found = 1; next }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /return/ { last = NR }
  !in_fn && !in_lam && index($0, "static inline void " lam) == 1 { in_lam = 1 }
  in_lam && /^}/ { in_lam = 0 }
  in_lam && !lamline && index($0, "return " fn "(x);") { lamline = NR }
  END {
    if (found && last) mode = "a"; else if (lamline) mode = "b"; else exit 3
    if (mode == "a") { endl = last; while (endl < NR && lines[endl] !~ /;[ \t]*$/) endl++ }
    for (i = 1; i <= NR; i++) {
      l = lines[i]
      if (mode == "a" && i == last) sub(/return /, "return (", l)
      if (mode == "a" && i == endl) sub(/;[ \t]*$/, ") + static_cast<T>(1.0f);", l)
      if (mode == "b" && i == lamline) {
        sub("return " fn "\\(x\\);", "return " fn "(x) + static_cast<decltype(x)>(1.0f);", l)
      }
      print l
    }
  }' "$ggml_src/element_wise.cpp" > "$out/mut/element_wise.cpp"
fi
mutrc=$?
if [ $mutrc != 0 ] || cmp -s "$ggml_src/element_wise.cpp" "$out/mut/element_wise.cpp"; then
  echo "mutant elementwise $op: FAIL (mutation did not apply: no function op_$op or lambda in ggml_sycl_op_$op)"; exit 1
fi
cp "$ggml_src/element_wise.hpp" "$ggml_src/common.hpp" "$out/mut/"
fail=0 notrun=0

# run SRCDIR NAME: builds and runs one variant (SRCDIR holds the element_wise.cpp to include); prints the verdict and keeps
# the run's output in $out/NAME.res. Returns 0 ok, 1 FAIL (the run failed its checks or exited nonzero), 2 SKIP (no
# device), 3 FAIL (build).
run() {
  local srcdir=$1 name=$2
  if ! "$root/scripts/sycl-build.sh" --backend=opencl -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED $layouts \
      -DEW_ID="$id" -DEW_OPNAME="$op" -DEW_CALL="$call" -DEW_LO="$lo" -DEW_HI="$hi" -DEW_P0="$p0" -DEW_P1="$p1" \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$here/ew_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "elementwise $op $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i "error\|refused\|undefined\|multiple" | head -6; return 3
  fi
  local res rc
  res=$(timeout 300 "$out/$name" 2>&1); rc=$?
  printf '%s\n' "$res" > "$out/$name.res"
  if [ $rc = 70 ]; then echo "SKIP: elementwise $op: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "checks: $nchecks, failed: 0" <<< "$res"; then
    echo "elementwise $op $name: ok, $nchecks of $nchecks checks ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "elementwise $op $name: FAIL (rc $rc)"; grep -v ': ok$' <<< "$res" | tail -20; return 1
}

# mutant_verdict FILE: classifies a mutant run's output. Returns 0 caught, 1 not caught, 2 NOT RUN.
# Caught needs a completed run (its "checks: N, failed: K" line, and nothing else but the device and check lines) in which
# every check reports mismatches. Any other line or a missing checks line means the mutant did not run to a wrong result.
mutant_verdict() {
  local f=$1 bad
  grep -q "^checks: $nchecks, failed: [0-9][0-9]*$" "$f" || return 2
  if grep -vqE "^(device: .*|checks: $nchecks, failed: [0-9]+|$op F32 [0-9x]+ (flat|strided): mismatches: [0-9]+ of [0-9]+, guard writes: [0-9]+ of 64, max abs err .*: (ok|FAIL))\$" "$f"; then
    return 2
  fi
  bad=$(grep -cE "^$op F32 [0-9x]+ (flat|strided): mismatches: [1-9][0-9]* of [0-9]+," "$f")
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
  3) echo "mutant elementwise $op: NOT RUN (build failed)"; notrun=$((notrun+1)) ;;
  *) mv=0; mutant_verdict "$out/opencl.mut.res" || mv=$?
     case $mv in
       0) echo "mutant elementwise $op: caught" ;;
       1) echo "mutant elementwise $op: FAIL (not caught)"; fail=1 ;;
       *) echo "mutant elementwise $op: NOT RUN (the run did not complete with wrong results; see above)"; notrun=$((notrun+1)) ;;
     esac ;;
esac
[ $notrun = 0 ] || { echo "NOT RUN: $notrun run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
