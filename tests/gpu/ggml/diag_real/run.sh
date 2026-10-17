#!/usr/bin/env bash
# The real ggml-sycl diag.cpp (ggml/src/ggml-sycl/diag.cpp, unchanged), compiled as a TU of diag_real.cpp through
# scripts/sycl-build.sh for OpenCL and Level Zero, linked against libggml-sycl.so and libggml-base.so from the llama.cpp
# build, and run on the Intel XPU for three shapes (source {ne0, 1, ne2, ne3}, output {ne0, ne0, ne2, ne3}) with 64 guard
# slots past the end of the output. A mutant (off-diagonal = src + 1; a sed copy of the real file) must fail on every
# shape. The link uses a version script that makes every symbol of the test executable local (see diag_real.cpp).
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
  || [ ! -f "$ggml_build/libggml-base.so" ] || [ ! -f "$ggml_build/libggml-sycl.so" ] || [ ! -f "$ggml_src/diag.cpp" ] \
  || ! ls "${oneapi_lib%%:*}"/libiomp5.so >/dev/null 2>&1; then
  echo "SKIP: gpu ggml diag_real: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE), libOpenCL.so.1, GGML_BUILD/libggml-{base,sycl}.so, GGML_SRC/diag.cpp and ONEAPI_LIB/libiomp5.so"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/clinc" "$out/mut"
ln -s "$clinc/CL" "$out/clinc/CL"   # only CL/: the oneAPI include tree's sycl/ would shadow the compat headers
export OPENCL_INCLUDE=$out/clinc
printf '{\n  local: *;\n};\n' > "$out/hide.map"   # the executable exports no symbols: libggml-sycl binds its own copies
export LD_LIBRARY_PATH=$oneapi_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
sed 's/dst\[dst_idx\] = T(0);/dst[dst_idx] = src[((i3 * ne2 + i2) * ne0) + i0] + T(1);/' "$ggml_src/diag.cpp" > "$out/mut/diag.cpp"
if ! grep -q 'T(1);' "$out/mut/diag.cpp"; then echo "diag_real: the mutant sed did not apply (diag.cpp changed?)"; exit 1; fi
cp "$ggml_src/diag.hpp" "$ggml_src/common.hpp" "$out/mut/"
shapes=("10 1 4 3" "79 1 19 13" "256 1 8 16")
fail=0; notrun=0

# run BACKEND SRCDIR NAME: builds diag_real.cpp against the diag.cpp in SRCDIR and runs it on every shape. Returns 0 when
# every shape passes, 2 when the runtime reports no device, 1 otherwise.
run() {
  local b=$1 srcdir=$2 name=$3 s res rc ok=0
  if ! "$root/scripts/sycl-build.sh" --backend="$b" -DGGML_SYCL_WARP_SIZE=16 -DGGML_SHARED \
      -I"$srcdir" -I"$root/lib/sycl-ggml" -I"$ggml_src" -I"$ggml_src/../../include" -I"$ggml_src/.." \
      "$root/tests/gpu/ggml/diag_real/diag_real.cpp" -o "$out/$name" \
      -L"$ggml_build" -lggml-sycl -lggml-base -Wl,-rpath,"$ggml_build" -L"$oneapi_lib" -Wl,-rpath,"$oneapi_lib" \
      -Wl,--version-script="$out/hide.map" \
      > "$out/$name.build" 2>&1; then
    echo "diag_real $b $name: FAIL (build)"; grep -v prelinker "$out/$name.build" | grep -i -A2 "error" | head -3; return 1
  fi
  for s in "${shapes[@]}"; do
    res=$(timeout 120 "$out/$name" $s 2>&1); rc=$?
    if [ $rc = 70 ] && ! grep -q "out of device memory" <<< "$res"; then echo "SKIP: diag_real $b: no device"; return 2; fi
    if [ $rc = 70 ]; then
      echo "diag_real $b $name [${s// /x}]: NOT RUN (out of device memory in the runtime heap)"; notrun=$((notrun+1)); continue
    fi
    if [ $rc = 0 ] && grep -q "mismatches: 0 of" <<< "$res" && grep -q "guard writes: 0 of" <<< "$res"; then
      echo "diag_real $b $name [${s// /x}]: ok ($(grep -m1 device: <<< "$res"))"
    else
      echo "diag_real $b $name [${s// /x}]: FAIL (rc $rc)"; echo "$res" | tail -3; ok=1
    fi
  done
  return $ok
}

for b in opencl level-zero; do
  rc=0; run "$b" "$ggml_src" "$b" || rc=$?
  case $rc in 0) ;; 2) continue ;; *) fail=1 ;; esac
  # the mutant: the off-diagonal writes src + 1, which the check must catch on every shape
  mrc=0; mo=$(run "$b" "$out/mut" "$b.mut") || mrc=$?
  echo "$mo" | grep -v "^diag_real $b $b.mut \[.*\]: FAIL (rc" | grep -v "^device\|^mismatches" || true
  if [ $mrc = 2 ]; then continue; fi
  n_caught=$(grep -c "^diag_real $b $b.mut \[.*\]: FAIL (rc" <<< "$mo")
  if [ "$n_caught" = "${#shapes[@]}" ]; then echo "mutant diag_real $b: caught on every shape"; else echo "mutant diag_real $b: FAIL (caught on $n_caught of ${#shapes[@]} shapes)"; fail=1; fi
done
[ $notrun = 0 ] || { echo "NOT RUN: $notrun shape run(s) did not run (see above); this is a failure, not a pass"; fail=1; }
exit $fail
