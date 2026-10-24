#!/usr/bin/env bash
# Build a SYCL program (lib/sycl, docs/notes/sycl-webgpu.md) for the host CPU or for WebGPU.
#
#   scripts/sycl-build.sh [--cpu] [--backend=webgpu|vulkan|opencl|level-zero] [--keep-ir] [--ndebug] [-I dir] [-D mac] [--cxx=CMD]
#                         [-L dir] [-l lib] [-Wl,...] [-rpath dir] prog.cpp -o prog
#
# WebGPU (the default): a device pass compiles prog.cpp with -D__NFCXX_SYCL_DEVICE__ through the Path B front end
# (scripts/pathb-dump --ir), scripts/pathb-wgsl-emit.rb lowers every kernel to WGSL, and the host pass compiles the
# program with -DNFCXX_SYCL_WEBGPU. The WGSL and the kernel table are written next to the output as prog.wgsl and
# prog.man; at run time the program finds them through NFCXX_SYCL_IMAGE (default: the output path, baked in). The
# server that executes them is tests/sycl/server.cjs (Node + Playwright's Chromium; see rt_pipe.hpp).
# --cpu: the host path only, no WGSL (the kernels are C++ loops).
# Link flags (-L, -l, -Wl,..., -rpath dir; -rpath becomes -Wl,-rpath,dir) go to the host compile only, after the source and
# -o; the device pass never sees them.
# -c, -fPIC: a host object instead of a program (OpenCL and Level Zero). The TU's image is written next to the object
# (obj.o.cl.spv, obj.o.man) and the object registers it, so objects linked into one program or one -shared library each
# bring their kernels (lib/sycl/include/sycl/rt_image.hpp). Link the objects with the host compiler (nfcxx a.o b.o).
# -shared and -rdynamic go to the host link like the other link flags.
# --ndebug: -DNDEBUG on the device pass only (the host pass keeps its asserts). For a TU that reaches ggml.h's assert() from a
# device-side function: the device pass refuses the call to the host __assert_fail, and the device has no assert to lower it to.
# --cxx=CMD: the host compiler (default: $CXX; else nfcxx for WebGPU when built, else g++). The closure types' mangling and
# layout must match the device pass's (this front end; g++ mostly agrees), because the host finds a kernel by
# typeid(F).name() and copies the closure bytes. The server refuses a closure whose size differs.
# Exit status 3 when the emitter refuses a kernel (the reason is on stderr).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/oneapi-env.sh"   # the oneAPI runtime libraries and OPENCL_INCLUDE, for the tools and compilers run below
cxx=${CXX:-}; mode=webgpu; backend=webgpu; out=""; src=""; keep=0; ndebug=; opts=(); link=(); hostopts=(); std=c++17
while [ $# -gt 0 ]; do
  case $1 in
    --cpu) mode=cpu ;;
    --backend=*) backend=${1#--backend=}; case $backend in webgpu|vulkan|opencl|level-zero) ;; *) echo "sycl-build: --backend must be webgpu, vulkan, opencl or level-zero" >&2; exit 2 ;; esac ;;
    --keep-ir) keep=1 ;;
    --ndebug) ndebug=-DNDEBUG ;;
    --cxx=*) cxx=${1#--cxx=} ;;
    -std=*) std=${1#-std=} ;;
    -o) out=$2; shift ;;
    -I|-D) opts+=("$1$2"); shift ;;
    -L|-l) [ $# -ge 2 ] || { echo "sycl-build: $1 needs an argument" >&2; exit 2; }; link+=("$1" "$2"); shift ;;
    -rpath) [ $# -ge 2 ] || { echo "sycl-build: -rpath needs an argument" >&2; exit 2; }; link+=("-Wl,-rpath,$2"); shift ;;
    -L*|-l*|-Wl,*|-shared|-rdynamic) link+=("$1") ;;
    -c|-fPIC|-fpic) hostopts+=("$1") ;;
    --diag_*) diag+=("$1") ;;                              # front-end (EDG) diagnostic options: the device pass only
    -I*|-D*|-U*|-O*|-g|-W*) opts+=("$1") ;;
    -*) echo "sycl-build: unknown option $1" >&2; exit 2 ;;
    *) src=$1 ;;
  esac
  shift
done
[ -n "$src" ] || { echo "usage: sycl-build.sh [--cpu] prog.cpp -o prog" >&2; exit 2; }
if [ ${#hostopts[@]} -gt 0 ] && { [ "$mode" = cpu ] || { [ $backend != opencl ] && [ $backend != level-zero ]; }; }; then
  echo "sycl-build: -c and -fPIC need --backend=opencl or level-zero (the other runtimes load one image per program)" >&2; exit 2
fi
[ -n "$out" ] || out=${src%.cpp}
# the host compiler: for a device backend, nfcxx when its EDG build is found (EDG_BUILD, default build/edg; EDG_BASE, default
# build/edg-base; the closure layouts then match the device pass by construction), else $CXX or g++. The device pass names a
# kernel closure in a file-local scope with EDG's module id (a CRC of the source's mtime and the working directory, --wdir /);
# g++ names it differently (ZL... against ZN41_INTERNAL_...), so g++ cannot host the device image. nfcxx without build/qbe
# compiles EDG's C through gcc (NFCXX_BACKEND=gcc).
if [ -z "$cxx" ]; then
  if [ "$mode" = webgpu ] && [ -x "$root/nfcxx" ] && [ -x "${EDG_BUILD:-$root/build/edg}/bin/eccp" ]; then
    cxx=$root/nfcxx
    export EDG_BUILD=${EDG_BUILD:-$root/build/edg} EDG_BASE=${EDG_BASE:-$root/build/edg-base}
    [ -x "$root/build/qbe/qbe" ] || export NFCXX_BACKEND=${NFCXX_BACKEND:-gcc}
  else
    cxx=g++
    [ "$mode" = cpu ] || echo "sycl-build: the host is g++, which names file-local kernel closures differently from the device pass (no kernel for the closure type); build nfcxx's EDG (build/edg, or EDG_BUILD) or pass --cxx" >&2
  fi
fi
inc=$root/lib/sycl/include
case $(basename "${cxx%% *}") in nfcxx) optflag="" ;; *) optflag="-O2" ;; esac   # nfcxx optimizes by itself; a plain compiler needs it for the host loops
if [ "$mode" = cpu ]; then
  exec $cxx -std=$std $optflag -I"$inc" "${opts[@]}" "$src" -o "$out" "${link[@]}"
fi
absout=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")
"$root/scripts/pathb-dump" --ir -std=$std -D__NFCXX_SYCL_DEVICE__ ${ndebug:+$ndebug} -I"$inc" "${opts[@]}" ${diag[@]+"${diag[@]}"} "$src" > "$absout.dev.ir"
rc=0
if [ $backend = vulkan ]; then
  "$root/scripts/mrb" "$root/scripts/pathb-spirv-emit.rb" --manifest="$absout.man" "$absout.dev.ir" > "$absout.spv" || rc=$?
elif [ $backend = opencl ] || [ $backend = level-zero ]; then
  # the Kernel-capability module (OpenCL 2.2): one kernel per entry point, the push block as its argument (OpenCL and Level Zero)
  "$root/scripts/mrb" "$root/scripts/pathb-spirv-emit.rb" --kernel-cl --manifest="$absout.man" "$absout.dev.ir" > "$absout.cl.spv" || rc=$?
else
  "$root/scripts/mrb" "$root/scripts/pathb-wgsl-emit.rb" --manifest="$absout.man" "$absout.dev.ir" > "$absout.wgsl" || rc=$?
fi
[ "$keep" = 1 ] || rm -f "$absout.dev.ir"
if [ $rc -ne 0 ]; then rm -f "$absout.wgsl" "$absout.spv" "$absout.cl.spv" "$absout.man"; echo "sycl-build: the device code of $src was refused (exit $rc)" >&2; exit $rc; fi
if [ $backend = vulkan ]; then
  if [ -s "$absout.spv" ] && ! spirv-val --target-env vulkan1.2 "$absout.spv" > "$absout.val.log" 2>&1; then
    cat "$absout.val.log" >&2; echo "sycl-build: the SPIR-V of $src does not validate" >&2; exit 1
  fi
  exec $cxx -std=$std $optflag -DNFCXX_SYCL_VULKAN -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" -I"$inc" "${opts[@]}" "$src" -o "$out" -lvulkan "${link[@]}"
fi
if [ $backend = opencl ] || [ $backend = level-zero ]; then
  if [ -s "$absout.cl.spv" ] && ! spirv-val --target-env opencl2.2 "$absout.cl.spv" > "$absout.val.log" 2>&1; then
    cat "$absout.val.log" >&2; echo "sycl-build: the OpenCL SPIR-V of $src does not validate" >&2; exit 1
  fi
fi
if [ $backend = level-zero ]; then
  # the Level Zero headers (/usr/include/level_zero) and loader (libze_loader.so.1; no dev symlink, so it is named by its file)
  [ ${#hostopts[@]} = 0 ] || exec $cxx -std=$std $optflag -DNFCXX_SYCL_LEVEL_ZERO -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" -I"$inc" \
    "${opts[@]}" "${hostopts[@]}" "$src" -o "$out"
  exec $cxx -std=$std $optflag -DNFCXX_SYCL_LEVEL_ZERO -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" -I"$inc" "${opts[@]}" "$src" -o "$out" \
    -l:libze_loader.so.1 "${link[@]}"
fi
if [ $backend = opencl ] && [ -n "${OPENCL_INCLUDE:-}" ] && [ -d "$OPENCL_INCLUDE/sycl" ]; then
  # the oneAPI include directory: only its CL/ is wanted. Its sycl/ would shadow lib/sycl's headers, and its
  # sycl/detail/kernel_desc.hpp makes nfcxx take a -c compile for a oneAPI SYCL source (the integration-header pre-pass).
  clinc=$root/build/opencl-include
  mkdir -p "$clinc" && ln -sfn "$OPENCL_INCLUDE/CL" "$clinc/CL" && OPENCL_INCLUDE=$clinc
fi
if [ $backend = opencl ]; then
  # the OpenCL headers: OPENCL_INCLUDE (the oneAPI compiler's, from scripts/oneapi-env.sh); libOpenCL.so.1 is the ICD loader
  # the search order: the user's -I/-D first, then the runtime's own headers, OPENCL_INCLUDE last (set by scripts/oneapi-env.sh). The oneAPI OpenCL
  # include directory also holds a sycl/ directory, so it must not shadow a user header of the same name.
  [ ${#hostopts[@]} = 0 ] || exec $cxx -std=$std $optflag -DNFCXX_SYCL_OPENCL -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" "${opts[@]}" \
    -I"$inc" ${OPENCL_INCLUDE:+"-I$OPENCL_INCLUDE"} "${hostopts[@]}" "$src" -o "$out"
  exec $cxx -std=$std $optflag -DNFCXX_SYCL_OPENCL -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" "${opts[@]}" -I"$inc" \
    ${OPENCL_INCLUDE:+"-I$OPENCL_INCLUDE"} "$src" -o "$out" -l:libOpenCL.so.1 "${link[@]}"
fi
exec $cxx -std=$std $optflag -DNFCXX_SYCL_WEBGPU -DNFCXX_SYCL_SERVER_JS="\"$root/tests/sycl/server.cjs\"" \
  -DNFCXX_SYCL_IMAGE_PREFIX="\"$absout\"" -I"$inc" "${opts[@]}" "$src" -o "$out" "${link[@]}"
