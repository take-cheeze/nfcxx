#!/usr/bin/env bash
# SYCL tests (lib/sycl, docs/notes/sycl-webgpu.md).
#   host path     each program builds with g++ and with nfcxx (--cpu) and prints its "ok" line.
#   OpenCL path   scripts/sycl-build.sh --backend=opencl: the Kernel-capability SPIR-V on an Intel GPU (rt_opencl.hpp).
#   Level Zero    scripts/sycl-build.sh --backend=level-zero: the same SPIR-V through the Level Zero API (rt_level_zero.hpp).
#   WebGPU path   scripts/sycl-build.sh compiles the device pass (WGSL) and the host side with nfcxx; the program runs the
#                 kernels through tests/sycl/server.cjs (Chromium's WebGPU: a GPU, or SwiftShader without one).
#                 Needs the Path B harness (scripts/setup-pathb.sh), the nfcxx build (setup-edg.sh, setup-qbe.sh), node,
#                 Playwright and a Chromium with WebGPU. The WebGPU part skips (exit 0) when one is missing.
# Programs:  pass: prints "NAME ok";  trap: the run fails with exit 71 and says why;  refuse: the device compile exits 3.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
nfcxx=$root/nfcxx
have_nfcxx=0
[ -x "$root/build/edg/bin/eccp" ] && [ -x "$root/build/qbe/qbe" ] && have_nfcxx=1

# ---- host path
for t in vecadd saxpy2d reduce bytes chain matmul usm usm_ptr tables libm groups barvar atomics redcustom double copysign slices mulhi std_array; do
  want="$t ok"
  if "$root/scripts/sycl-build.sh" --cpu "$t.cpp" -o "$out/$t.g++" > "$out/$t.log" 2>&1 && [ "$("$out/$t.g++" | tail -1)" = "$want" ]; then
    echo "host g++   $t: ok"
  else
    echo "host g++   $t: FAIL"; tail -3 "$out/$t.log"; fail=1
  fi
  # redcustom has a volatile store in a kernel: the qbe backend cannot compile it for the host path (cproc), the WebGPU path never does
  if [ $have_nfcxx = 1 ] && [ "$t" != redcustom ]; then
    if "$root/scripts/sycl-build.sh" --cpu --cxx="$nfcxx" "$t.cpp" -o "$out/$t.nfcxx" > "$out/$t.log" 2>&1 && [ "$("$out/$t.nfcxx" | tail -1)" = "$want" ]; then
      echo "host nfcxx $t: ok"
    else
      echo "host nfcxx $t: FAIL"; tail -3 "$out/$t.log"; fail=1
    fi
  fi
done

# ---- Vulkan path (scripts/pathb-spirv-emit.rb, lib/sycl/include/sycl/rt_vulkan.hpp): the same programs on a Vulkan compute
# device (lavapipe in CI; any device with bufferDeviceAddress, Int64, Float64 and the Vulkan memory model). Skips when the
# loader, spirv-val or a device is missing.
vk_ok=0
libvk=$(ldconfig -p 2>/dev/null | grep libvulkan || true)
if [ $have_nfcxx = 1 ] && command -v spirv-val >/dev/null && [ -n "$libvk" ]; then vk_ok=1; fi
if [ $vk_ok = 1 ]; then
  vkbuild() { "$root/scripts/sycl-build.sh" --backend=vulkan --cxx="$nfcxx" "$1.cpp" -o "$out/vk_$1" > "$out/vk_$1.log" 2>&1; }
  vkprobe=1
  for t in vecadd saxpy2d reduce bytes chain matmul usm usm_ptr tables libm groups barvar atomics redcustom double copysign slices mulhi std_array vulkan_slab; do
    if ! vkbuild $t; then echo "vulkan     $t: FAIL (build)"; grep -v prelinker "$out/vk_$t.log" | head -3; fail=1; continue; fi
    "$out/vk_$t" > "$out/vk_$t.out" 2> "$out/vk_$t.err"; rc=$?
    if [ $rc = 70 ] && grep -q "Vulkan runtime" "$out/vk_$t.err"; then vkprobe=0; break; fi
    if [ "$(tail -1 "$out/vk_$t.out")" = "$t ok" ]; then echo "vulkan     $t: ok"; else echo "vulkan     $t: FAIL (exit $rc)"; cat "$out/vk_$t.err" "$out/vk_$t.out" | tail -3; fail=1; fi
  done
  if [ $vkprobe = 0 ]; then
    echo "SKIP: vulkan: no usable Vulkan device ($(head -c 120 "$out/vk_vecadd.err" 2>/dev/null))"
  else
    if vkbuild trap_div; then
      "$out/vk_trap_div" > /dev/null 2> "$out/vk_trap_div.err"; rc=$?
      if [ $rc = 71 ] && grep -q "division by zero" "$out/vk_trap_div.err"; then echo "vulkan     trap_div: trapped (exit 71)"; else echo "vulkan     trap_div: FAIL (exit $rc)"; cat "$out/vk_trap_div.err"; fail=1; fi
    else echo "vulkan     trap_div: FAIL (build)"; fail=1; fi
  fi
else
  echo "SKIP: vulkan: needs the nfcxx build, spirv-val and libvulkan"
fi

# ---- OpenCL path (scripts/pathb-spirv-emit.rb --kernel-cl, lib/sycl/include/sycl/rt_opencl.hpp): the same programs on an Intel
# GPU through OpenCL (SPIR-V 1.2 with the OpenCL 2.2 memory model, the heap in shared USM, the local size in specialization
# constants). Skips when the OpenCL headers, the ICD loader, spirv-val or a usable device is missing. The host is g++ (the
# runtime is plain C++ over the OpenCL C API).
cl_inc=${OPENCL_INCLUDE:-}
cl_ok=0
if command -v spirv-val >/dev/null && [ -f "$cl_inc/CL/cl.h" ] && [ -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then cl_ok=1; fi
if [ $cl_ok = 1 ]; then
  clbuild() { OPENCL_INCLUDE=$cl_inc "$root/scripts/sycl-build.sh" --backend=opencl "$1.cpp" -o "$out/cl_$1" > "$out/cl_$1.log" 2>&1; }
  clprobe=1
  for t in vecadd saxpy2d reduce bytes chain matmul usm usm_ptr tables libm groups barvar atomics redcustom double copysign slices mulhi std_array; do
    if ! clbuild $t; then echo "opencl    $t: FAIL (build)"; grep -v prelinker "$out/cl_$t.log" | head -3; fail=1; continue; fi
    "$out/cl_$t" > "$out/cl_$t.out" 2> "$out/cl_$t.err"; rc=$?
    if [ $rc = 70 ] && grep -q "OpenCL runtime" "$out/cl_$t.err"; then clprobe=0; break; fi
    if [ "$(tail -1 "$out/cl_$t.out")" = "$t ok" ]; then echo "opencl    $t: ok"; else echo "opencl    $t: FAIL (exit $rc)"; cat "$out/cl_$t.err" "$out/cl_$t.out" | tail -3; fail=1; fi
  done
  if [ $clprobe = 0 ]; then
    echo "SKIP: opencl: no usable OpenCL device ($(head -c 120 "$out/cl_vecadd.err" 2>/dev/null))"
  elif clbuild trap_div; then
    "$out/cl_trap_div" > /dev/null 2> "$out/cl_trap_div.err"; rc=$?
    if [ $rc = 71 ] && grep -q "division by zero" "$out/cl_trap_div.err"; then echo "opencl    trap_div: trapped (exit 71)"; else echo "opencl    trap_div: FAIL (exit $rc)"; cat "$out/cl_trap_div.err"; fail=1; fi
  else echo "opencl    trap_div: FAIL (build)"; fail=1; fi
else
  echo "SKIP: opencl: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"
fi

# ---- closure names (closure_name.cpp, OpenCL): a kernel closure in a translation unit whose module id falls back to the
# working directory (the ggml-sycl dpct helper leaves the TU without a candidate). The device pass and the host build must
# name the closure alike. Needs GGML_SRC (the llama.cpp ggml-sycl source directory, which holds dpct/helper.hpp); skips without it.
ggml_src=${GGML_SRC:-/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl}
if [ $cl_ok = 1 ] && [ -f "$ggml_src/dpct/helper.hpp" ]; then
  if OPENCL_INCLUDE=$cl_inc "$root/scripts/sycl-build.sh" --backend=opencl -DCLOSURE_NAME_DPCT -I"$ggml_src" -I"$root/lib/sycl-ggml" \
      closure_name.cpp -o "$out/cl_closure_name" > "$out/cl_closure_name.log" 2>&1 \
     && [ "$("$out/cl_closure_name" | tail -1)" = "closure_name ok" ]; then
    echo "opencl    closure_name: ok"
  else
    echo "opencl    closure_name: FAIL"; grep -v prelinker "$out/cl_closure_name.log" | tail -3; fail=1
  fi
elif [ $cl_ok = 1 ]; then
  echo "SKIP: closure_name: needs GGML_SRC/dpct/helper.hpp (the ggml-sycl source directory)"
fi

# ---- Level Zero path (scripts/pathb-spirv-emit.rb --kernel-cl, lib/sycl/include/sycl/rt_level_zero.hpp): the same module as the
# OpenCL path, run on an Intel GPU through the Level Zero API (the heap in shared USM with atomics, the local size in
# specialization constants, one immediate command list). Skips when the Level Zero headers, the loader, spirv-val or a usable
# device is missing. The host is the default compiler (the runtime is plain C++ over ze_api.h).
lz_ok=0
if command -v spirv-val >/dev/null && [ -f /usr/include/level_zero/ze_api.h ] && [ -e /usr/lib/x86_64-linux-gnu/libze_loader.so.1 ]; then lz_ok=1; fi
if [ $lz_ok = 1 ]; then
  lzbuild() { "$root/scripts/sycl-build.sh" --backend=level-zero "$1.cpp" -o "$out/lz_$1" > "$out/lz_$1.log" 2>&1; }
  lzprobe=1
  for t in vecadd saxpy2d reduce bytes chain matmul usm usm_ptr tables libm groups barvar atomics redcustom double copysign slices mulhi std_array; do
    if ! lzbuild $t; then echo "level-zero $t: FAIL (build)"; grep -v prelinker "$out/lz_$t.log" | head -3; fail=1; continue; fi
    "$out/lz_$t" > "$out/lz_$t.out" 2> "$out/lz_$t.err"; rc=$?
    if [ $rc = 70 ] && grep -q "Level Zero runtime" "$out/lz_$t.err"; then lzprobe=0; break; fi
    if [ "$(tail -1 "$out/lz_$t.out")" = "$t ok" ]; then echo "level-zero $t: ok"; else echo "level-zero $t: FAIL (exit $rc)"; cat "$out/lz_$t.err" "$out/lz_$t.out" | tail -3; fail=1; fi
  done
  if [ $lzprobe = 0 ]; then
    echo "SKIP: level-zero: no usable Level Zero device ($(head -c 120 "$out/lz_vecadd.err" 2>/dev/null))"
  elif lzbuild trap_div; then
    "$out/lz_trap_div" > /dev/null 2> "$out/lz_trap_div.err"; rc=$?
    if [ $rc = 71 ] && grep -q "division by zero" "$out/lz_trap_div.err"; then echo "level-zero trap_div: trapped (exit 71)"; else echo "level-zero trap_div: FAIL (exit $rc)"; cat "$out/lz_trap_div.err"; fail=1; fi
  else echo "level-zero trap_div: FAIL (build)"; fail=1; fi
else
  echo "SKIP: level-zero: needs spirv-val, the Level Zero headers (/usr/include/level_zero) and libze_loader.so.1"
fi

# ---- WebGPU path
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ $have_nfcxx = 0 ] || ! command -v node >/dev/null || ! node server.cjs --probe >/dev/null 2>&1; then
  echo "SKIP: sycl webgpu: needs the Path B harness, the nfcxx build, node, Playwright and a Chromium with WebGPU"
  exit $fail
fi
export NFCXX_SYCL_NODE=${NFCXX_SYCL_NODE:-node}
build() { "$root/scripts/sycl-build.sh" --cxx="$nfcxx" "$1.cpp" -o "$out/$1" > "$out/$1.log" 2>&1; }
for t in vecadd saxpy2d reduce bytes chain matmul usm tables libm groups barvar atomics redcustom slices; do
  if build $t && [ "$("$out/$t" 2>"$out/$t.err" | tail -1)" = "$t ok" ]; then
    echo "webgpu     $t: ok"
  else
    echo "webgpu     $t: FAIL"; tail -3 "$out/$t.log" "$out/$t.err" 2>/dev/null; fail=1
  fi
done
# a trap: the kernel divides by zero
if build trap_div; then
  "$out/trap_div" > "$out/trap_div.out" 2> "$out/trap_div.err"; rc=$?
  if [ $rc = 71 ] && grep -q "division by zero" "$out/trap_div.err"; then echo "webgpu     trap_div: trapped (exit 71)"; else echo "webgpu     trap_div: FAIL (exit $rc)"; cat "$out/trap_div.err"; fail=1; fi
else echo "webgpu     trap_div: FAIL (build)"; tail -3 "$out/trap_div.log"; fail=1; fi
# a refusal: double (WebGPU core has no f64; Vulkan has it, see double.cpp)
rc=0; "$root/scripts/sycl-build.sh" --cxx="$nfcxx" refuse_double.cpp -o "$out/refuse_double" > "$out/refuse.log" 2>&1 || rc=$?
if [ $rc = 3 ] && grep -q "double" "$out/refuse.log"; then echo "webgpu     refuse_double: refused (exit 3)"; else echo "webgpu     refuse_double: FAIL (exit $rc)"; cat "$out/refuse.log"; fail=1; fi
exit $fail
