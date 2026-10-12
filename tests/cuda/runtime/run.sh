#!/usr/bin/env bash
# CUDA runtime and library calls that llama.cpp's ggml-cuda uses, through the nfcxx driver (see docs/notes/gpu.md).
# Each program must build, link, run on the GPU and print its expected line:
#   launchex   cudaLaunchKernelEx with a registered kernel (the launch goes through the kernel registry)
#   devprops   cudaGetDeviceProperties and cudaDeviceGetAttribute agree
#   graph      a registered kernel launched in a stream capture, then cudaGraphLaunch
#   cublas     cublasSgemm on 16x16 matrices against a host product (links with -lcublas)
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda), libcublas and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || [ ! -f "$cuda/include/cublas_v2.h" ] \
   || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: runtime: needs cuda_runtime.h, libcudart, cublas_v2.h and nvidia-smi (CUDA_HOME)"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out

pass() {  # pass NAME EXPECTED-SUBSTRING [extra link flags]
  local name=$1 want=$2 extra=${3:-}
  if "$root/nfcxx" -c -I"$cuda/include" "$name.cu" -o "$out/$name.o" > "$out/$name.log" 2>&1 \
     && "$root/nfcxx" "$out/$name.o" -L"$cuda/lib64" -lcudart $extra -o "$out/$name" >> "$out/$name.log" 2>&1 \
     && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$name") && [[ "$run" == *"$want"* ]]; then
    echo "pass $name: $run"
  else
    echo "FAIL $name"; grep -v "pragma\|NV_SILENCE\|^ *\^\|^ *$\|warning" "$out/$name.log" | head -5; fail=1
  fi
}

pass launchex "launchex: no error, 0 mismatches"
pass devprops "devprops: no error"
pass graph "graph: no error, 0 mismatches"
pass cublas_gemm "cublas: status 0, 0 mismatches" "-lcublas"
exit $fail
