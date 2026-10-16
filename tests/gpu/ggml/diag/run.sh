#!/usr/bin/env bash
# The llama.cpp testbed (docs/notes/ggml-sycl.md): ggml-sycl's F32 diag op (diag_kernel.cpp, the kernel and its nd_range
# launch copied from ggml/src/ggml-sycl/diag.cpp) built with scripts/sycl-build.sh for OpenCL and Level Zero, run on the
# Intel XPU for three shapes, with 64 guard slots past the end of the output. A mutant (off-diagonal = src value + 1) must
# fail on every shape. Needs the OpenCL headers (OPENCL_INCLUDE), spirv-val on PATH and the Intel GPU runtime; skips
# (exit 0) when one is missing, and a backend whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu ggml diag: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"; exit 0
fi
export OPENCL_INCLUDE=$clinc
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0; notrun=0
# the source shapes ne0 ne1 ne2 ne3 (ne1 = 1); the output is {ne0, ne0, ne2, ne3}
shapes=("10 1 4 3" "79 1 19 13" "256 1 8 16")

# check BACKEND BIN: runs BIN on every shape and prints one verdict per shape.
# returns 0 when all pass, 2 when the runtime reports no device, 1 otherwise.
check() {
  local b=$1 bin=$2 s res rc ok=0
  for s in "${shapes[@]}"; do
    res=$(timeout 120 "$bin" $s 2>&1); rc=$?
    if [ $rc = 70 ] && ! grep -q "out of device memory" <<< "$res"; then echo "SKIP: diag $b: no device"; return 2; fi
    if [ $rc = 70 ]; then
      # the runtime's heap cannot hold this dispatch (invocations x stack bytes): the shape did not run, which is reported, not passed
      echo "diag $b [${s// /x}]: NOT RUN (out of device memory in the runtime heap)"; notrun=$((notrun+1)); continue
    fi
    if [ $rc = 0 ] && grep -q "mismatches: 0 of" <<< "$res" && grep -q "guard writes: 0 of" <<< "$res"; then
      echo "diag $b [${s// /x}]: ok ($(grep -m1 device: <<< "$res"))"
    else
      echo "diag $b [${s// /x}]: FAIL (rc $rc)"; echo "$res" | tail -3; ok=1
    fi
  done
  return $ok
}

for b in opencl level-zero; do
  if ! "$root/scripts/sycl-build.sh" --backend="$b" diag_kernel.cpp -o "$out/$b" > "$out/$b.build" 2>&1; then
    echo "diag $b: FAIL (build)"; grep -v prelinker "$out/$b.build" | head -3; fail=1; continue
  fi
  rc=0; check $b "$out/$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac

  # the mutant: the off-diagonal writes src + 1, which the check must catch on every shape
  sed 's/dst\[dst_idx\] = T(0);/dst[dst_idx] = src[((i3 * ne2 + i2) * ne0) + i0] + T(1);/' diag_kernel.cpp > "$out/$b.mut.cpp"
  if ! "$root/scripts/sycl-build.sh" --backend="$b" "$out/$b.mut.cpp" -o "$out/$b.mut" > "$out/$b.mut.build" 2>&1; then
    echo "mutant diag $b: FAIL (build)"; fail=1; continue
  fi
  mrc=0
  for s in "${shapes[@]}"; do
    res=$(timeout 120 "$out/$b.mut" $s 2>&1); r=$?
    if [ $r = 70 ] && grep -q "out of device memory" <<< "$res"; then
      echo "mutant diag $b [${s// /x}]: NOT RUN (out of device memory in the runtime heap)"; notrun=$((notrun+1)); continue
    fi
    if ! grep -q "mismatches: [1-9]" <<< "$res" && ! grep -q "guard writes: [1-9]" <<< "$res"; then
      echo "mutant diag $b [${s// /x}]: not caught (rc $r)"; mrc=1
    fi
  done
  if [ $mrc = 0 ]; then echo "mutant diag $b: caught on every shape that ran"; else fail=1; fi
done
[ $notrun = 0 ] || echo "NOT RUN: $notrun shape run(s) hit the runtime heap limit (see above)"
exit $fail
