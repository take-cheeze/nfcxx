#!/usr/bin/env bash
# Kernel name obfuscation across linked libraries (static and shared) and mixed plain/obfuscated objects.
# Each library defines kshared with different behaviour and the same template instance; the program must reach each one.
# Needs the CUDA toolkit and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: obfuscate linked: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
fail=0
run() { local name=$1; shift; local r; r=$("$@" 2>&1) || { echo "FAIL $name: $r"; fail=1; return; }
  if [[ "$r" == *"total mismatches: 0"* ]]; then echo "pass $name: 0 mismatches"; else echo "FAIL $name: $r"; fail=1; fi; }
ob() { NFCXX_OBFUSCATE_KERNELS=1 NFCXX_OBFUSCATE_SEED=$1 "$root/scripts/nfcxx-cuda" -c "$2" -o "$3" > "$3.log" 2>&1; }
ob 00112233445566778899aabbccddeeff libA.cu "$out/libA.o" && ob "" libB.cu "$out/libB.o" && NFCXX_OBFUSCATE_KERNELS=1 "$root/scripts/nfcxx-cuda" -c main.cu -o "$out/main.o" > "$out/main.log" 2>&1 \
  || { echo "FAIL compile"; cat "$out"/*.log 2>/dev/null; exit 1; }
# Static: the program links both archives.
ar rcs "$out/libA.a" "$out/libA.o"; ar rcs "$out/libB.a" "$out/libB.o"
"$root/nfcxx" "$out/main.o" "$out/libA.a" "$out/libB.a" -o "$out/prog_static" -L"$cuda/lib64" -lcudart > "$out/lk.log" 2>&1 || { echo "FAIL link static"; cat "$out/lk.log"; exit 1; }
run "static libraries" "$out/prog_static"
# Shared: each library built position-independent, loaded at run time.
NFCXX_OBFUSCATE_KERNELS=1 NFCXX_OBFUSCATE_SEED=00112233445566778899aabbccddeeff "$root/scripts/nfcxx-cuda" -c libA.cu -Xcompiler -fPIC -o "$out/libA_pic.o" > /dev/null 2>&1
NFCXX_OBFUSCATE_KERNELS=1 "$root/scripts/nfcxx-cuda" -c libB.cu -Xcompiler -fPIC -o "$out/libB_pic.o" > /dev/null 2>&1
"$root/nfcxx" -shared -fPIC "$out/libA_pic.o" -o "$out/libA.so" -L"$cuda/lib64" -lcudart > /dev/null 2>&1
"$root/nfcxx" -shared -fPIC "$out/libB_pic.o" -o "$out/libB.so" -L"$cuda/lib64" -lcudart > /dev/null 2>&1
"$root/nfcxx" "$out/main.o" -o "$out/prog_shared" -L"$out" -lA -lB -L"$cuda/lib64" -lcudart -Wl,-rpath,"$out" > "$out/lkS.log" 2>&1 || { echo "FAIL link shared"; cat "$out/lkS.log"; exit 1; }
run "shared libraries" "$out/prog_shared"
exit $fail
