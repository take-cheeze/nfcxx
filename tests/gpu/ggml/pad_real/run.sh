#!/usr/bin/env bash
# The real ggml-sycl pad.cpp (ggml/src/ggml-sycl/pad.cpp, unchanged), compiled as a TU of pad_real.cpp through
# scripts/sycl-build.sh for OpenCL and Level Zero, linked against libggml-sycl.so and libggml-base.so from the llama.cpp
# build, and run on the Intel XPU (GGML_OP_PAD, F32) for the test_pad and test_pad_ext shapes below, one with strided source
# rows, with 64 guard slots past the end of the output. A mutant (the padding writes 1 instead of 0; a sed copy of the real
# file) must fail on every shape. The link uses a version script that makes every symbol of the test executable local (see pad_real.cpp).
# Env: GGML_BUILD (the build bin dir, libggml-sycl.so and libggml-base.so), GGML_SRC (the ggml-sycl source dir), ONEAPI_LIB
# (the oneAPI runtime lib dirs, colon-separated), SPIRV_TOOLS_BIN (the directory holding spirv-val, when not on PATH),
# OPENCL_INCLUDE (the OpenCL headers). Skips (exit 0) when one is missing; a backend whose runtime reports no device
# (exit 70) is skipped; a shape the runtime cannot dispatch is reported NOT RUN and fails the test.
set -uo pipefail
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
ggml_build=${GGML_BUILD:-/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin}
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
oneapi_lib=${ONEAPI_LIB:-/opt/intel/oneapi/compiler/2026.1/lib:/opt/intel/oneapi/mkl/2026.1/lib:/opt/intel/oneapi/tbb/latest/lib:/opt/intel/oneapi/umf/latest/lib}
clinc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if ! command -v spirv-val >/dev/null || [ ! -f "$clinc/CL/cl.h" ] || [ ! -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ] \
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/pad.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml pad_real: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/pad.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
sed 's/dst\[dst_idx\] = 0.0f;/dst[dst_idx] = 1.0f;/' "$ggml_src/pad.cpp" > "$out/mut/pad.cpp"
if ! grep -q 'dst\[dst_idx\] = 1.0f;' "$out/mut/pad.cpp"; then echo "pad_real: the mutant sed did not apply (pad.cpp changed?)"; exit 1; fi
cp "$ggml_src/pad.hpp" "$ggml_src/common.hpp" "$out/mut/"
# ne0 ne1 ne2 ne3, lp0 rp0 lp1 rp1 lp2 rp2 lp3 rp3, extra row pitch: test_pad's {512,512}, {1024,16} and {1023,1} cases,
# test_pad_ext's padding of all four dimensions, and the same with strided source rows
shapes=("512 512 1 1 1 1 1 1 0 0 0 0 0" "1024 16 1 1 0 1 0 1 0 0 0 0 0" "1023 1 1 1 1 0 1 0 0 0 0 0 0"
        "33 17 3 2 1 1 1 1 1 1 1 1 0" "33 17 3 2 2 1 0 3 1 0 0 1 5")
fail=0; notrun=0

# run BACKEND SRCDIR NAME: builds pad_real.cpp against the pad.cpp in SRCDIR and runs it on every shape. Returns 0 when
# every shape passes, 2 when the runtime reports no device, 1 otherwise.
run() {
  local b=$1 srcdir=$2 name=$3 s res rc ok=0
  if ! "$root/scripts/sycl-build.sh" --backend="$b" -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$root/tests/gpu/ggml/pad_real/pad_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "pad_real $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i -A2 "error" | head -3; return 1
  fi
  for s in "${shapes[@]}"; do
    res=$(timeout 120 "$out/$name" $s 2>&1); rc=$?
    if [ $rc = 70 ] && ! grep -q "out of device memory" <<< "$res"; then echo "SKIP: pad_real $b: no device"; return 2; fi
    if [ $rc = 70 ]; then
      echo "pad_real $b $name [${s// /x}]: NOT RUN (out of device memory in the runtime heap)"; notrun=$((notrun+1)); continue
    fi
    if [ $rc = 0 ] && grep -q "mismatches: 0 of" <<< "$res" && grep -q "guard writes: 0 of" <<< "$res"; then
      echo "pad_real $b $name [${s// /x}]: ok ($(grep -m1 device: <<< "$res"))"
    else
      echo "pad_real $b $name [${s// /x}]: FAIL (rc $rc)"; echo "$res" | tail -3; ok=1
    fi
  done
  return $ok
}

for b in opencl level-zero; do
  rc=0; run "$b" "$ggml_src" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: the padding writes 1, which the check must catch on every shape
  mrc=0; mo=$(run "$b" "$out/mut" "$b.mut") || mrc=$?
  echo "$mo" | grep -v "^pad_real $b $b.mut \[.*\]: FAIL (rc" | grep -v "^device\|^mismatches" || true
  if [ $mrc = 2 ]; then continue; fi
  n_caught=$(grep -c "^pad_real $b $b.mut \[.*\]: FAIL (rc" <<< "$mo")
  if [ "$n_caught" = "${#shapes[@]}" ]; then echo "mutant pad_real $b: caught on every shape"; else echo "mutant pad_real $b: FAIL (caught on $n_caught of ${#shapes[@]} shapes)"; fail=1; fi
done
[ $notrun = 0 ] || { echo "NOT RUN: $notrun shape run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
