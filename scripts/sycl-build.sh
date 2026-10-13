#!/usr/bin/env bash
# Build a SYCL program (lib/sycl, docs/notes/sycl-webgpu.md) for the host CPU or for WebGPU.
#
#   scripts/sycl-build.sh [--cpu] [--backend=webgpu|vulkan] [--keep-ir] [-I dir] [-D mac] [--cxx=CMD] prog.cpp -o prog
#
# WebGPU (the default): a device pass compiles prog.cpp with -D__NFCXX_SYCL_DEVICE__ through the Path B front end
# (scripts/pathb-dump --ir), scripts/pathb-wgsl-emit.rb lowers every kernel to WGSL, and the host pass compiles the
# program with -DNFCXX_SYCL_WEBGPU. The WGSL and the kernel table are written next to the output as prog.wgsl and
# prog.man; at run time the program finds them through NFCXX_SYCL_IMAGE (default: the output path, baked in). The
# server that executes them is tests/sycl/server.cjs (Node + Playwright's Chromium; see rt_pipe.hpp).
# --cpu: the host path only, no WGSL (the kernels are C++ loops).
# --cxx=CMD: the host compiler (default: $CXX; else nfcxx for WebGPU when built, else g++). The closure types' mangling and
# layout must match the device pass's (this front end; g++ mostly agrees), because the host finds a kernel by
# typeid(F).name() and copies the closure bytes. The server refuses a closure whose size differs.
# Exit status 3 when the emitter refuses a kernel (the reason is on stderr).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cxx=${CXX:-}; mode=webgpu; backend=webgpu; out=""; src=""; keep=0; opts=(); std=c++17
while [ $# -gt 0 ]; do
  case $1 in
    --cpu) mode=cpu ;;
    --backend=*) backend=${1#--backend=}; case $backend in webgpu|vulkan) ;; *) echo "sycl-build: --backend must be webgpu or vulkan" >&2; exit 2 ;; esac ;;
    --keep-ir) keep=1 ;;
    --cxx=*) cxx=${1#--cxx=} ;;
    -std=*) std=${1#-std=} ;;
    -o) out=$2; shift ;;
    -I|-D) opts+=("$1$2"); shift ;;
    -I*|-D*|-U*|-O*|-g|-W*|-l*|-L*) opts+=("$1") ;;
    -*) echo "sycl-build: unknown option $1" >&2; exit 2 ;;
    *) src=$1 ;;
  esac
  shift
done
[ -n "$src" ] || { echo "usage: sycl-build.sh [--cpu] prog.cpp -o prog" >&2; exit 2; }
[ -n "$out" ] || out=${src%.cpp}
# the host compiler: for WebGPU, nfcxx when it is built (the closure layouts then match the device pass by construction), else $CXX or g++
if [ -z "$cxx" ]; then
  if [ "$mode" = webgpu ] && [ -x "$root/build/edg/bin/eccp" ] && [ -x "$root/build/qbe/qbe" ]; then cxx=$root/nfcxx; else cxx=g++; fi
fi
inc=$root/lib/sycl/include
case $(basename "${cxx%% *}") in nfcxx) optflag="" ;; *) optflag="-O2" ;; esac   # nfcxx optimizes by itself; a plain compiler needs it for the host loops
if [ "$mode" = cpu ]; then
  exec $cxx -std=$std $optflag -I"$inc" "${opts[@]}" "$src" -o "$out"
fi
absout=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")
"$root/scripts/pathb-dump" --ir -std=$std -D__NFCXX_SYCL_DEVICE__ -I"$inc" "${opts[@]}" "$src" > "$absout.dev.ir"
rc=0
if [ $backend = vulkan ]; then
  "$root/scripts/mrb" "$root/scripts/pathb-spirv-emit.rb" --manifest="$absout.man" "$absout.dev.ir" > "$absout.spv" || rc=$?
else
  "$root/scripts/mrb" "$root/scripts/pathb-wgsl-emit.rb" --manifest="$absout.man" "$absout.dev.ir" > "$absout.wgsl" || rc=$?
fi
[ "$keep" = 1 ] || rm -f "$absout.dev.ir"
if [ $rc -ne 0 ]; then rm -f "$absout.wgsl" "$absout.spv" "$absout.man"; echo "sycl-build: the device code of $src was refused (exit $rc)" >&2; exit $rc; fi
if [ $backend = vulkan ]; then
  if [ -s "$absout.spv" ] && ! spirv-val --target-env vulkan1.2 "$absout.spv" > "$absout.val.log" 2>&1; then
    cat "$absout.val.log" >&2; echo "sycl-build: the SPIR-V of $src does not validate" >&2; exit 1
  fi
  exec $cxx -std=$std $optflag -DNFCXX_SYCL_VULKAN -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" -I"$inc" "${opts[@]}" "$src" -o "$out" -lvulkan
fi
exec $cxx -std=$std $optflag -DNFCXX_SYCL_WEBGPU -DNFCXX_SYCL_SERVER_JS="\"$root/tests/sycl/server.cjs\"" \
  -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" -I"$inc" "${opts[@]}" "$src" -o "$out"
