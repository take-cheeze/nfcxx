#!/usr/bin/env bash
# WebGPU (Dawn, Vulkan) testbed on the Intel Arc B60: vecadd.cpp checks a 50000-element vector add (must report 0
# mismatches), a mutant shader (a - b) must fail that check, bench.cpp times launch overhead and throughput through
# Dawn, and opencl_bench.c runs the same small-dispatch shapes through OpenCL (NEO) for comparison.
# Needs the Dawn build (DAWN_BUILD, default /home/takecheeze/dev/third/dawn/build), its headers (DAWN_INCLUDE, a
# colon-separated list, default the source include dir and the generated include dir of that build) and the Intel
# Vulkan adapter. The OpenCL part needs OPENCL_INCLUDE (set by scripts/oneapi-env.sh) and
# libOpenCL.so.1 plus an Intel OpenCL GPU. Skips (exit 0) when the Dawn build or the Intel Vulkan adapter is missing;
# the OpenCL part is skipped on its own.
set -euo pipefail
cd "$(dirname "$0")"

DAWN_BUILD=${DAWN_BUILD:-/home/takecheeze/dev/third/dawn/build}
DAWN_SRC=$(dirname "$DAWN_BUILD")
DAWN_INCLUDE=${DAWN_INCLUDE:-$DAWN_SRC/include:$DAWN_BUILD/gen/include}
. ../../../scripts/oneapi-env.sh   # OPENCL_INCLUDE (the oneAPI compiler's) and LD_LIBRARY_PATH

if [ ! -f "$DAWN_BUILD/src/dawn/native/libwebgpu_dawn.a" ] || [ ! -f "$DAWN_BUILD/src/dawn/libdawn_proc.a" ] \
   || [ ! -f "$DAWN_BUILD/gen/include/dawn/webgpu_cpp.h" ]; then
  echo "SKIP: gpu webgpu: no Dawn build at DAWN_BUILD=$DAWN_BUILD"; exit 0
fi

mapfile -t libs < <(find "$DAWN_BUILD" -name '*.a' | sort)
incs=()
IFS=: read -ra inc_dirs <<< "$DAWN_INCLUDE"
for d in "${inc_dirs[@]}"; do incs+=("-I$d"); done

out=$(mktemp -d)  # binaries only; this script never deletes anything

cxx() {  # cxx SRC OUT: builds one WebGPU program against the Dawn build
  # -Wno-strict-aliasing: the generated webgpu_cpp.h punns StringView pointers in its SetLabel wrappers.
  g++ -std=c++20 -O2 -Wall -Wno-strict-aliasing "${incs[@]}" "$1" -o "$2" -Wl,--start-group "${libs[@]}" -Wl,--end-group -lpthread -ldl
}

fail=0

# 1. The vector add must match on the Intel Vulkan adapter; no Intel adapter is a skip.
cxx vecadd.cpp "$out/vecadd"
set +e
run=$("$out/vecadd" 2>&1); rc=$?
set -e
echo "$run"
if [ $rc = 2 ] && grep -q "no Intel Vulkan adapter" <<< "$run"; then
  echo "SKIP: gpu webgpu: no Intel Vulkan adapter"; exit 0
fi
if [ $rc = 0 ] && grep -q "mismatches: 0 of 50000" <<< "$run"; then echo "vecadd: ok"; else echo "vecadd: FAIL"; fail=1; fi

# 2. Mutant: the shader computes a - b and must be caught.
set +e
mut=$("$out/vecadd" --mutant 2>&1); mrc=$?
set -e
echo "$mut"
if [ $mrc != 0 ] && grep -q "mismatches: [1-9]" <<< "$mut"; then echo "mutant vecadd: caught"; else echo "mutant vecadd: FAIL (not caught)"; fail=1; fi

# 3. Dawn benchmark (launch overhead and throughput).
cxx bench.cpp "$out/bench"
"$out/bench" || { echo "bench: FAIL"; fail=1; }

# 4. OpenCL counterpart of the small-dispatch benchmark.
if [ -f "$OPENCL_INCLUDE/CL/cl.h" ] && [ -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  gcc -O2 -Wall -I"$OPENCL_INCLUDE" opencl_bench.c -o "$out/opencl_bench" -l:libOpenCL.so.1
  set +e
  ocl=$("$out/opencl_bench" 2>&1); orc=$?
  set -e
  echo "$ocl"
  if [ $orc = 2 ]; then echo "SKIP: gpu webgpu opencl: no Intel OpenCL GPU"
  elif [ $orc != 0 ]; then echo "opencl bench: FAIL"; fail=1; fi
else
  echo "SKIP: gpu webgpu opencl: needs OPENCL_INCLUDE/CL/cl.h and libOpenCL.so.1"
fi

exit $fail
