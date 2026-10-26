#!/usr/bin/env bash
# The CUDA driver API through the CUDA runtime (scripts/cuda-driver-shim, scripts/cuda-driver-wrap.sh;
# docs/notes/cuda-driver.md): a link that names libcuda gets the shim and libcudart instead.
#   - with a stand-in libcudart (fakecudart.c): the version and stream flags each call asks for, eleven arguments
#     through the trampoline, failures and the local error strings, one lookup per function (expected.txt); built by
#     gcc with the archive, by nfcc (--cuda-driver=cudart) and nfcxx (the default) on both backends;
#   - --cuda-driver=libcuda keeps libcuda; a CMake project linking CUDA::cuda_driver (cmake/) with nfcc as its C
#     compiler, both ways;
#   - with the real libcudart (CUDA_HOME/lib64): the program needs no libcuda.so.1; without a driver cuInit returns
#     CUDA_ERROR_NO_DEVICE, with one (nvidia-smi) it succeeds; the same bundled (--bundle-libs), and with
#     libcudart_static when the toolkit has it (then only glibc is needed).
# Needs cuda.h and cudaTypedefs.h in CUDA_HOME/include (CUDA 12.5 or later; scripts/fetch-cuda-libs.sh gives them).
#   NFCXX_BACKEND=gcc|qbe   (default: both, for the nfcc and nfcxx cases)
cd "$(dirname "$0")/../../.."
cuda=${CUDA_HOME:-/usr/local/cuda}
d=tests/cuda/driver
if [ ! -f "$cuda/include/cuda.h" ] || [ ! -f "$cuda/include/cudaTypedefs.h" ] || [ "$(uname -m)" != x86_64 ]; then
  echo "SKIP: driver: needs cuda.h and cudaTypedefs.h (CUDA_HOME) on x86-64"; exit 0
fi
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -z "${2:-}" ] || head -20 <<<"$2"; fail=1; }
if ! shim=$(scripts/cuda-driver-shim "$cuda/include" 2>&1); then bad "cuda-driver-shim" "$shim"; exit 1; fi
ok "cuda-driver-shim: $(grep -c '^X(' "$(dirname "$shim")/nfcxx_cudrv_table.inc") driver functions"

# The stand-in runtime, as a CUDA_HOME of its own (the real headers, the stand-in library).
fake=$tmp/fake; mkdir -p "$fake/lib64"; ln -s "$(cd "$cuda/include" && pwd)" "$fake/include"
gcc -shared -fPIC $d/fakecudart.c -Wl,-soname,libcudart.so.12 -o "$fake/lib64/libcudart.so.12" &&
  ln -s libcudart.so.12 "$fake/lib64/libcudart.so" || { bad "stand-in libcudart"; exit 1; }
# drv.c and expected.txt are the 12.9 headers' calls and versions (cuCtxCreate takes 3 arguments there, 4 in 13.x;
# cuEventElapsedTime_v2 is new in 12.8): other headers run the cases below only.
hver=$(sed -n 's/^#define CUDA_VERSION \([0-9]*\).*/\1/p' "$cuda/include/cuda.h")
if [ "$hver" = 12090 ]; then
  gcc -c -DCUDA_API_PER_THREAD_DEFAULT_STREAM -I"$cuda/include" $d/drv_ptds.c -o "$tmp/drv_ptds.o" || { bad "drv_ptds.c"; exit 1; }
  check() {  # check NAME EXE
    local out
    out=$("$2" 2>&1)
    if [ "$out" != "$(cat $d/expected.txt)" ]; then bad "$1" "$(diff $d/expected.txt <(echo "$out"))"; return; fi
    case $(readelf -dW "$2" | grep NEEDED) in *libcuda.so*) bad "$1: needs libcuda" ;; *) ok "$1" ;; esac
  }
  if out=$(gcc -I"$cuda/include" $d/drv.c "$tmp/drv_ptds.o" "$shim" -L"$fake/lib64" -lcudart -Wl,-rpath,"$fake/lib64" -o "$tmp/gcc" 2>&1); then
    check "gcc with the shim archive" "$tmp/gcc"
  else bad "gcc with the shim archive (build)" "$out"; fi
  for be in $backends; do
    if out=$(CUDA_HOME=$fake NFCXX_BACKEND=$be ./nfcc --cuda-driver=cudart -I"$cuda/include" $d/drv.c "$tmp/drv_ptds.o" -lcuda \
               -Wl,-rpath,"$fake/lib64" -o "$tmp/nfcc-$be" 2>&1); then check "nfcc $be --cuda-driver=cudart" "$tmp/nfcc-$be"
    else bad "nfcc $be --cuda-driver=cudart (build)" "$out"; fi
    if [ -x "${EDG_BUILD:-build/edg}/bin/eccp" ]; then
      if out=$(CUDA_HOME=$fake NFCXX_BACKEND=$be ./nfcxx -I"$cuda/include" $d/drv.cpp "$tmp/drv_ptds.o" -lcuda \
                 -o "$tmp/nfcxx-$be" 2>&1); then check "nfcxx $be (the default)" "$tmp/nfcxx-$be"
      else bad "nfcxx $be (the default; build)" "$out"; fi
    fi
  done
else
  echo "skip the stand-in runtime cases (cuda.h is $hver; they are written for 12090)"
fi
# --cuda-driver=libcuda keeps libcuda (a stub of it here, as the toolkit's lib64/stubs/libcuda.so).
mkdir -p "$fake/lib64/stubs"
gcc -shared -fPIC $d/stub.c -Wl,-soname,libcuda.so.1 -o "$fake/lib64/stubs/libcuda.so" || bad "libcuda stub"
if out=$(CUDA_HOME=$fake ./nfcc --cuda-driver=libcuda -I"$cuda/include" $d/real.c "$fake/lib64/stubs/libcuda.so" -o "$tmp/keep" 2>&1); then
  case $(readelf -dW "$tmp/keep" | grep NEEDED) in *libcuda.so.1*) ok "--cuda-driver=libcuda keeps libcuda" ;; *) bad "--cuda-driver=libcuda" ;; esac
else bad "--cuda-driver=libcuda (build)" "$out"; fi
# CMake: CUDA::cuda_driver is the stub by absolute path. FindCUDAToolkit wants an nvcc; it only asks for its version.
if command -v cmake >/dev/null; then
  mkdir -p "$fake/bin"
  printf '#!/bin/sh\necho "Cuda compilation tools, release 12.9, V12.9.86"\n' > "$fake/bin/nvcc"; chmod +x "$fake/bin/nvcc"
  for m in auto libcuda; do
    b=$tmp/cmake-$m
    if out=$(env -u CUDA_HOME NFCXX_CUDA_DRIVER=$m cmake -S $d/cmake -B "$b" -G Ninja -DCMAKE_C_COMPILER="$PWD/nfcc" -DCUDAToolkit_ROOT="$fake" 2>&1 &&
             env -u CUDA_HOME NFCXX_CUDA_DRIVER=$m cmake --build "$b" 2>&1); then
      n=$(readelf -dW "$b/real" | grep NEEDED)
      case $m:$n in
        auto:*libcuda.so*) bad "CMake CUDA::cuda_driver: still needs libcuda" ;;
        auto:*libcudart.so.12*) got=$("$b/real" 2>&1)  # the stand-in libcudart answers, and says what it was asked
          case $got in
            "request cuInit 2000 1"*"cuInit CUDA_SUCCESS devices some") ok "CMake CUDA::cuda_driver through libcudart" ;;
            *) bad "CMake CUDA::cuda_driver (run)" "$got" ;;
          esac ;;
        libcuda:*libcuda.so.1*) ok "CMake CUDA::cuda_driver with NFCXX_CUDA_DRIVER=libcuda keeps libcuda" ;;
        *) bad "CMake CUDA::cuda_driver ($m)" "$n" ;;
      esac
    else bad "CMake CUDA::cuda_driver ($m; build)" "$out"; fi
  done
else
  echo "skip CMake (no cmake)"
fi
# -c: no link, nothing to replace.
if out=$(./nfcc --cuda-driver=cudart -c -I"$cuda/include" $d/real.c -o "$tmp/drv.o" 2>&1) && [ -f "$tmp/drv.o" ]; then ok "nfcc --cuda-driver=cudart -c"
else bad "nfcc --cuda-driver=cudart -c" "$out"; fi
out=$(./nfcc --cuda-driver=nvidia -c -I"$cuda/include" $d/real.c -o "$tmp/x.o" 2>&1; echo "rc=$?")
case $out in *"cudart or libcuda"*"rc=2"*) ok "an unknown --cuda-driver is refused" ;; *) bad "unknown --cuda-driver" "$out" ;; esac

# The real libcudart.
if [ -e "$cuda/lib64/libcudart.so" ] || [ -e "$cuda/lib64/libcudart.so.12" ]; then
  if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then want="cuInit CUDA_SUCCESS devices some"
  else want="cuInit CUDA_ERROR_NO_DEVICE devices none"; fi
  if out=$(./nfcc --cuda-driver=cudart -I"$cuda/include" $d/real.c -lcuda -Wl,-rpath,"$cuda/lib64" -o "$tmp/real" 2>&1); then
    got=$("$tmp/real" 2>&1)
    case "$(readelf -dW "$tmp/real" | grep NEEDED)" in
      *libcuda.so*) bad "real libcudart: the program needs libcuda" ;;
      *) [ "$got" = "$want" ] && ok "real libcudart: $got" || bad "real libcudart: want '$want'" "$got" ;;
    esac
    # Bundled: cudart inside, the driver still outside (never bundled).
    if out=$(./nfcc --bundle-libs --cuda-driver=cudart -I"$cuda/include" $d/real.c -L"$cuda/lib64" -lcuda -o "$tmp/real.b" 2>&1); then
      got=$("$tmp/real.b" 2>&1)
      case "$(readelf -dW "$tmp/real.b" | grep NEEDED)" in
        *libcudart*|*libcuda.so*) bad "real libcudart bundled: still needs $(readelf -dW "$tmp/real.b" | grep -o 'libcud[a-z]*\.so[.0-9]*')" ;;
        *) [ "$got" = "$want" ] && ok "real libcudart bundled (--bundle-libs): $got" || bad "real libcudart bundled: want '$want'" "$got" ;;
      esac
    else bad "real libcudart bundled (build)" "$out"; fi
    # The static runtime: the shim binds to it and no shared libcudart is added.
    if [ -f "$cuda/lib64/libcudart_static.a" ]; then
      if out=$(./nfcc -I"$cuda/include" $d/real.c -L"$cuda/lib64" -lcuda -lcudart_static -lpthread -ldl -lrt -o "$tmp/real.s" 2>&1); then
        got=$("$tmp/real.s" 2>&1)
        case "$(readelf -dW "$tmp/real.s" | grep NEEDED)" in
          *libcudart*|*libcuda.so*) bad "libcudart_static: needs $(readelf -dW "$tmp/real.s" | grep -o 'libcud[a-z]*\.so[.0-9]*')" ;;
          *) [ "$got" = "$want" ] && ok "libcudart_static: glibc only, $got" || bad "libcudart_static: want '$want'" "$got" ;;
        esac
      else bad "libcudart_static (build)" "$out"; fi
    else
      echo "skip libcudart_static (not in CUDA_HOME/lib64)"
    fi
  else bad "real libcudart (build)" "$out"; fi
else
  echo "skip real libcudart (not in CUDA_HOME/lib64)"
fi
exit $fail
