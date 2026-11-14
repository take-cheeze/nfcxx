#!/usr/bin/env bash
# emitopts.cpp built with scripts/sycl-build.rb for Level Zero and OpenCL, as a debug build and as a release build (--ndebug
# --no-div-trap, as the ggml-sycl library is built), run on the Intel XPU, and the release module checked with spirv-dis:
#   - no trap at all (OpAtomicUMax on the flag): --no-checks drops the null-pointer and bounds checks, a division or shift by
#     a constant has no guard;
#   - the dead flag is never read: no function can trap, so no call is followed by its test;
#   - the divisions and remainders by constants divide by the constant itself (no select of a guarded divisor);
#   - dpct::dp4a(int, int, int) is OpSDot (lib/sycl-ggml/sycl/nfcxx_dpct_dp4a.hpp, the emitters' __nfcxx_sycl_dp4a);
#   - the push block parameter is FuncParamAttr NoAlias and NoWrite.
# A third build skips the IR passes (NFCXX_IR_OPT=off NFCXX_CFG=none NFCXX_FORWARD=off), so the kernel keeps its many
# small slots (the vec temporaries, the local array, the struct argument): the ones whose address stays in their function
# are private (a Function-storage word array instead of the invocation's stack), and the results must not change.
# Needs spirv-val and spirv-dis; a backend whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
if ! command -v spirv-val >/dev/null || ! command -v spirv-dis >/dev/null; then
  echo "SKIP: gpu emitopts: needs spirv-val and spirv-dis"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0

# run BACKEND NAME OPTIONS...: builds emitopts.cpp with the options and runs it
run() {
  local b=$1 n=$2; shift 2
  if ! "$root/scripts/sycl-build.rb" --backend="$b" "$@" -I"$root/lib/sycl-ggml" emitopts.cpp -o "$out/$n" > "$out/$n.build" 2>&1; then
    echo "emitopts $n: FAIL (build)"; grep -v prelinker "$out/$n.build" | head -3; return 1
  fi
  local res rc
  res=$(timeout 300 "$out/$n" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: emitopts $n: no device"; return 0; fi
  if [ $rc = 0 ] && [ "$(tail -1 <<< "$res")" = "emitopts ok" ]; then echo "emitopts $n: ok"; return 0; fi
  echo "emitopts $n: FAIL (run rc=$rc)"; echo "$res" | head -6; return 1
}

for b in level-zero opencl; do
  [ $b = opencl ] && { [ -f "${OPENCL_INCLUDE:-}/CL/cl.h" ] || { echo "SKIP: emitopts opencl: no OpenCL headers"; continue; }; }
  run $b $b-debug || fail=1
  run $b $b-release --ndebug --no-div-trap || fail=1
done
NFCXX_IR_OPT=off NFCXX_CFG=none NFCXX_FORWARD=off run level-zero level-zero-raw --ndebug --no-div-trap || fail=1

# the module checks (the release module of Level Zero, the same module as OpenCL's)
check() {   # check NAME COUNT CONDITION: CONDITION is a test on COUNT, e.g. "-eq 0"
  local what=$1 n=$2; shift 2
  if [ "$n" "$@" ]; then echo "emitopts module: $what ok ($n)"; else echo "emitopts module: FAIL: $what ($n, want $*)"; fail=1; fi
}
for n in level-zero-release level-zero-debug level-zero-raw; do
  [ -s "$out/$n.cl.spv" ] || { echo "emitopts module $n: FAIL (no module)"; fail=1; continue; }
  spirv-dis "$out/$n.cl.spv" -o "$out/$n.dis"
done
if [ -s "$out/level-zero-release.dis" ]; then
  d=$out/level-zero-release.dis
  check "release: traps" "$(grep -c 'OpAtomicUMax' "$d")" -eq 0
  # the dead flag is each function's third state parameter, a Function-storage uint pointer (the stack pointer is a ulong one)
  deads=$(grep -E '= OpFunctionParameter %_ptr_Function_uint$' "$d" | sed 's/ *=.*//' | tr '\n' '|' | sed 's/|$//')
  if [ -n "$deads" ]; then reads=$(grep -cE "OpLoad %uint ($deads)( |$)" "$d"); else reads=0; fi
  check "release: dead flag reads" "$reads" -eq 0
  check "release: divisions by a constant" "$(grep -cE 'Op(UDiv|UMod|SDiv|SRem) %uint %[0-9a-z_]+ %u?int_(n?[0-9]+)$' "$d")" -ge 4
  check "release: OpSDot" "$(grep -c 'OpSDot' "$d")" -ge 1
  check "release: push block NoAlias" "$(grep -c 'FuncParamAttr NoAlias' "$d")" -ge 1
  check "release: push block NoWrite" "$(grep -c 'FuncParamAttr NoWrite' "$d")" -ge 1
fi
if [ -s "$out/level-zero-debug.dis" ]; then
  d=$out/level-zero-debug.dis
  check "debug: traps kept (bounds check of the local array)" "$(grep -c 'OpAtomicUMax' "$d")" -ge 1
  check "debug: divisions by a constant" "$(grep -cE 'Op(UDiv|UMod|SDiv|SRem) %uint %[0-9a-z_]+ %u?int_(n?[0-9]+)$' "$d")" -ge 4
  check "debug: OpSDot" "$(grep -c 'OpSDot' "$d")" -ge 1
fi
if [ -s "$out/level-zero-raw.dis" ]; then
  check "raw: private slots" "$(grep -c 'OpVariable %_ptr_Function__arr_uint' "$out/level-zero-raw.dis")" -ge 1
fi
exit $fail
