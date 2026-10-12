#!/usr/bin/env bash
# assert in device code (the device unit's assert is a trap on a failed condition): pass.cu's conditions hold and
# the kernel runs; trap.cu's condition fails, so the launch reports an error. Needs CUDA_HOME and an NVIDIA GPU;
# skips (exit 0) when they are missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: devassert: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
fail=0
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
export TMPDIR=$out
export NFCXX_BACKEND=${NFCXX_BACKEND:-gcc}   # the CUDA runtime headers do not compile on the qbe backend
build() { "$root/nfcxx" -c -I"$cuda/include" "$1.cu" -o "$out/$1.o" > "$out/$1.log" 2>&1 && "$root/nfcxx" "$out/$1.o" -L"$cuda/lib64" -lcudart -o "$out/$1" >> "$out/$1.log" 2>&1; }
if build pass && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/pass") && [ "$run" = "no error 10" ]; then
  echo "pass devassert: $run"
else
  echo "FAIL pass devassert: ${run:-build failed}"; fail=1
fi
# trap.cu prints the launch's error: a false condition must trap the kernel (not 'no error').
if build trap && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/trap" 2>&1) && [[ "$run" == "unspecified launch failure"* ]]; then
  echo "trap devassert: $run"
else
  echo "FAIL trap devassert: a false condition did not trap: ${run:-build failed}"; fail=1
fi
exit $fail
