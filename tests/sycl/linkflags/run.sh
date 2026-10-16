#!/usr/bin/env bash
# Link flags for the host pass of scripts/sycl-build.sh (-L, -l, -Wl,..., -rpath dir). The test builds libgreet.so
# (greet.cpp, int greet(void) returns 42) into a temporary lib directory, then:
#   host       prog.cpp calls greet and prints "linked ok" when it gets 42; built with --cpu and -L/-l/-Wl,-rpath
#              (and, in a second build, with -rpath dir); the device pass never sees these flags.
#   opencl     ../vecadd.cpp built with --backend=opencl and the same link flags, run on an Intel GPU (skips without one).
# Skips (exit 0) when the library cannot be built into the lib directory.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
lib=$out/lib
mkdir -p "$lib"
if ! g++ -shared -fPIC -o "$lib/libgreet.so" greet.cpp > "$out/greet.log" 2>&1 || [ ! -f "$lib/libgreet.so" ]; then
  echo "SKIP: linkflags: cannot build libgreet.so into $lib ($(head -c 200 "$out/greet.log"))"
  exit 0
fi

# ---- host: -L, -l and -Wl,-rpath, then the same with -rpath dir (the driver's own spelling of the same option)
if "$root/scripts/sycl-build.sh" --cpu -L"$lib" -lgreet -Wl,-rpath,"$lib" prog.cpp -o "$out/prog" > "$out/prog.log" 2>&1 \
   && [ "$("$out/prog" | tail -1)" = "linked ok" ]; then
  echo "linkflags  host -Wl,-rpath: ok"
else
  echo "linkflags  host -Wl,-rpath: FAIL"; tail -3 "$out/prog.log"; fail=1
fi
if "$root/scripts/sycl-build.sh" --cpu -L "$lib" -l greet -rpath "$lib" prog.cpp -o "$out/prog2" > "$out/prog2.log" 2>&1 \
   && [ "$("$out/prog2" | tail -1)" = "linked ok" ]; then
  echo "linkflags  host -rpath: ok"
else
  echo "linkflags  host -rpath: FAIL"; tail -3 "$out/prog2.log"; fail=1
fi

# ---- opencl: the device pass must ignore the link flags (a -l or -L in it fails the device compile)
cl_inc=${OPENCL_INCLUDE:-/opt/intel/oneapi/compiler/2026.1/include}
if command -v spirv-val >/dev/null && [ -f "$cl_inc/CL/cl.h" ] && [ -e /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 ]; then
  if OPENCL_INCLUDE=$cl_inc "$root/scripts/sycl-build.sh" --backend=opencl -L"$lib" -lgreet -Wl,-rpath,"$lib" ../vecadd.cpp -o "$out/cl_vecadd" > "$out/cl.log" 2>&1; then
    "$out/cl_vecadd" > "$out/cl.out" 2> "$out/cl.err"; rc=$?
    if [ $rc = 70 ] && grep -q "OpenCL runtime" "$out/cl.err"; then
      echo "SKIP: linkflags opencl: no usable OpenCL device ($(head -c 120 "$out/cl.err"))"
    elif [ "$(tail -1 "$out/cl.out")" = "vecadd ok" ]; then
      echo "linkflags  opencl vecadd: ok"
    else
      echo "linkflags  opencl vecadd: FAIL (exit $rc)"; cat "$out/cl.err" "$out/cl.out" | tail -3; fail=1
    fi
  else
    echo "linkflags  opencl vecadd: FAIL (build)"; grep -v prelinker "$out/cl.log" | head -3; fail=1
  fi
else
  echo "SKIP: linkflags opencl: needs spirv-val, the OpenCL headers (OPENCL_INCLUDE) and libOpenCL.so.1"
fi
exit $fail
