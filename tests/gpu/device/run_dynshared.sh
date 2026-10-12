#!/usr/bin/env bash
# Dynamic extern shared memory end to end: dynshared.cu goes through the driver (the rewrite, the device compile with
# the __nfcxx_dynshared_addr lowering, the embedded cubin) and runs on the GPU with the byte count passed in the launch.
# A mutant (the output adds 2 instead of 1, in a scratch copy) must build and then fail. Skips (exit 0) without the
# toolkit or a GPU.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: dynshared: needs the CUDA runtime and a GPU"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out
run_env="$cuda/lib64:/usr/lib/x86_64-linux-gnu"
build() { # build SRC OUTNAME: compile and link through the driver; the log is in $out/OUTNAME.log
  "$root/nfcxx" -c -I"$cuda/include" "$1" -o "$out/$2.o" > "$out/$2.log" 2>&1 \
    && "$root/nfcxx" "$out/$2.o" -L"$cuda/lib64" -lcudart -o "$out/$2" >> "$out/$2.log" 2>&1
}
if build dynshared.cu dynshared; then
  if LD_LIBRARY_PATH="$run_env" "$out/dynshared"; then echo "run dynshared: ok"; else echo "run dynshared: FAIL"; fail=1; fi
else
  cat "$out/dynshared.log"; echo "build dynshared: FAIL"; fail=1
fi
sed 's/out\[i\] = buf\[t\] + 1.0f;/out[i] = buf[t] + 2.0f;/' dynshared.cu > "$out/mut.cu"
if ! build "$out/mut.cu" mut; then
  cat "$out/mut.log"; echo "mutant dynshared: FAIL (did not build)"; fail=1
elif LD_LIBRARY_PATH="$run_env" "$out/mut" > "$out/mut.out" 2>&1; then
  echo "mutant dynshared: FAIL (not caught)"; fail=1
else
  echo "mutant dynshared: caught ($(tail -1 "$out/mut.out"))"
fi
exit $fail
