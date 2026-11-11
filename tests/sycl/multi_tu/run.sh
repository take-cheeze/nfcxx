#!/usr/bin/env bash
# Several TUs with kernels in one program (lib/sycl/include/sycl/rt_image.hpp): scale.cpp, shift.cpp and main.cpp are each
# compiled with scripts/sycl-build.sh -c (an object and its device image), then (1) the three objects are linked into one
# program and (2) scale.o and shift.o go into a shared library that the program links. Each kernel reads a table of its own
# TU, so a kernel run with another image's statics fails the check. Both on OpenCL and on Level Zero. A mutant (shift.cpp's
# table changed) must fail. Needs spirv-val, the OpenCL headers, the Level Zero loader and an Intel GPU; a backend whose
# runtime reports no device (exit 70) is skipped.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
. "$root/scripts/oneapi-env.sh"   # LD_LIBRARY_PATH (the oneAPI runtime) and OPENCL_INCLUDE
export PATH=${SPIRV_TOOLS_BIN:+$SPIRV_TOOLS_BIN:}$PATH
if ! command -v spirv-val >/dev/null || [ ! -f "${OPENCL_INCLUDE:-}/CL/cl.h" ] || [ ! -x "$root/build/edg/bin/eccp" ]; then
  echo "SKIP: sycl multi_tu: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and the nfcxx build (build/edg)"; exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
export EDG_BUILD=${EDG_BUILD:-$root/build/edg} EDG_BASE=${EDG_BASE:-$root/build/edg-base}
[ -x "$root/build/qbe/qbe" ] || export NFCXX_BACKEND=${NFCXX_BACKEND:-gcc}

# build BACKEND DIR SHIFT_SRC: the three objects of one variant in DIR
build() {
  local b=$1 d=$2 shift_src=$3
  mkdir -p "$d"
  "$root/scripts/sycl-build.sh" --backend=$b -c -fPIC scale.cpp -o "$d/scale.o" &&
  "$root/scripts/sycl-build.sh" --backend=$b -c -fPIC "$shift_src" -o "$d/shift.o" &&
  "$root/scripts/sycl-build.sh" --backend=$b -c main.cpp -o "$d/main.o"
}

# verdict NAME RC OUTPUT: 0 ok, 1 FAIL, 2 SKIP (no device)
verdict() {
  local name=$1 rc=$2 res=$3
  if [ $rc = 70 ]; then echo "SKIP: multi_tu $name: no device ($(tail -1 <<< "$res"))"; return 2; fi
  if [ $rc = 0 ] && [ "$(tail -1 <<< "$res")" = "multi_tu ok" ]; then echo "multi_tu $name: ok"; return 0; fi
  echo "multi_tu $name: FAIL (rc $rc)"; tail -3 <<< "$res"; return 1
}

for b in opencl level-zero; do
  case $b in opencl) rtlib=-l:libOpenCL.so.1 ;; level-zero) rtlib=-l:libze_loader.so.1 ;; esac
  d=$out/$b
  if ! build $b "$d" shift.cpp > "$d.log" 2>&1; then echo "multi_tu $b: FAIL (build)"; grep -v prelinker "$d.log" | head -5; fail=1; continue; fi
  # (1) one program of three objects
  if "$root/nfcxx" "$d/main.o" "$d/scale.o" "$d/shift.o" -o "$d/prog" $rtlib > "$d.link.log" 2>&1; then
    rc=0; res=$(timeout 120 "$d/prog" 2>&1) || rc=$?
    verdict "$b objects" $rc "$res"; case $? in 1) fail=1 ;; 2) continue ;; esac
  else
    echo "multi_tu $b objects: FAIL (link)"; head -5 "$d.link.log"; fail=1
  fi
  # (2) scale and shift in a shared library
  if "$root/nfcxx" -shared "$d/scale.o" "$d/shift.o" -o "$d/libmt.so" $rtlib > "$d.so.log" 2>&1 &&
     "$root/nfcxx" "$d/main.o" -o "$d/prog_so" -L"$d" -lmt -Wl,-rpath,"$d" $rtlib >> "$d.so.log" 2>&1; then
    rc=0; res=$(timeout 120 "$d/prog_so" 2>&1) || rc=$?
    verdict "$b shared library" $rc "$res"; [ $? = 1 ] && fail=1
  else
    echo "multi_tu $b shared library: FAIL (link)"; head -5 "$d.so.log"; fail=1
  fi
  # the mutant: shift.cpp's table changed; the program of objects must fail
  sed 's/{10, 20, 30, 40}/{10, 21, 30, 40}/' shift.cpp > "$out/shift_mut.cpp"
  m=$out/$b.mut
  if build $b "$m" "$out/shift_mut.cpp" > "$m.log" 2>&1 && "$root/nfcxx" "$m/main.o" "$m/scale.o" "$m/shift.o" -o "$m/prog" $rtlib > "$m.link.log" 2>&1; then
    if timeout 120 "$m/prog" > /dev/null 2>&1; then echo "mutant multi_tu $b: FAIL (not caught)"; fail=1; else echo "mutant multi_tu $b: caught"; fi
  else
    echo "mutant multi_tu $b: FAIL (build)"; fail=1
  fi
done
exit $fail
