#!/usr/bin/env bash
# The llama.cpp testbed rung 1 (docs/notes/ggml-sycl.md): ggml-sycl's F32 fill op (fill_kernel.cpp, the kernel and its
# nd_range launch copied from ggml/src/ggml-sycl/fill.cpp) built with scripts/sycl-build.sh for OpenCL and Level Zero, run
# on the Intel XPU over 2069793 elements, with 64 guard slots past the end. A mutant (fill value + 1) must fail. Needs the
# OpenCL headers (OPENCL_INCLUDE), spirv-val on PATH and the Intel GPU runtime; skips (exit 0) when one is missing, and a
# backend whose runtime reports no device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  echo "SKIP: gpu ggml fill: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"; exit 0
fi
export OPENCL_INCLUDE=$clinc
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0

# run BACKEND SOURCE NAME: builds and runs one variant; prints the verdict.
run() {
  local b=$1 src=$2 name=$3
  if ! "$root/scripts/sycl-build.sh" --backend="$b" "$src" -o "$out/$name" > "$out/$name.build" 2>&1; then
    echo "fill $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | head -3; return 1
  fi
  local res rc
  res=$(timeout 120 "$out/$name" 2>&1); rc=$?
  if [ $rc = 70 ]; then echo "SKIP: fill $b: no device"; return 2; fi
  if [ $rc = 0 ] && grep -q "mismatches: 0 of" <<< "$res" && grep -q "guard writes: 0 of" <<< "$res"; then
    echo "fill $b $name: ok ($(grep -m1 device: <<< "$res"))"; return 0
  fi
  echo "fill $b $name: FAIL (rc $rc)"; echo "$res" | tail -3; return 1
}

for b in opencl level-zero; do
  cp fill_kernel.cpp "$out/$b.fill.cpp"
  rc=0; run $b "$out/$b.fill.cpp" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: the fill writes value + 1, which the check must catch
  sed 's/dst\[i\] = value;/dst[i] = value + 1;/' fill_kernel.cpp > "$out/$b.mut.cpp"
  if run $b "$out/$b.mut.cpp" "$b.mut" >/dev/null 2>&1; then echo "mutant fill $b: FAIL (not caught)"; fail=1; else echo "mutant fill $b: caught"; fi
done
exit $fail
