#!/usr/bin/env bash
# llama.cpp ggml-cuda through the nfcxx driver: one representative file per blocker from the probe
# (tests/llamacpp/cuda/probe.sh; the full table is written by the probe). Each file must still fail with its recorded
# first error. A file that now compiles, or whose error changed, fails the test, so the record gets updated.
# No ggml-cuda file compiles through the driver yet, so this is the compile-only check of the current state.
# Skips (exit 0, with the reason) when the llama.cpp clone or the CUDA headers are missing.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
llama=${LLAMA:-$root/build/targets/llama.cpp}
cuda=${CUDA_HOME:-/usr/local/cuda}
src=$llama/ggml/src/ggml-cuda
if [ ! -d "$src" ] || [ ! -f "$cuda/include/cuda_runtime.h" ]; then
  echo "SKIP: llama.cpp clone ($src) or CUDA headers ($cuda) missing"; exit 0
fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
export NFCXX_BACKEND=gcc
fail=0
# file | the recorded first error (a substring of the driver's output)
while IFS='|' read -r f want; do
  [ -n "$f" ] || continue
  log=$out/$(echo "$f" | tr / _).log
  if TMPDIR=$out timeout 600 "$root/nfcxx" -c -std=c++17 -DGGML_USE_CUDA -I"$cuda/include" -I"$cuda/include/cccl" \
     -I"$llama/ggml/include" -I"$llama/ggml/src" -I"$src" "$src/$f" -o "$out/o.o" > "$log" 2>&1; then
    echo "NOW COMPILES $f: update the probe record"; fail=1
  elif tr '\n' ' ' < "$log" | tr -s ' ' | grep -qF -- "$want"; then   # the compiler wraps long messages
    echo "known blocker $f: $want"
  else
    echo "CHANGED $f: expected [$want]"; grep -m1 -E ' error|refused:|cannot open' "$log" | sed 's/^ */  /' | cut -c1-200; fail=1
  fi
done <<'LIST'
acc.cu|identifier "__syncwarp" is undefined
template-instances/fattn-vec-instance-f16-q5_0.cu|cannot open source file "../fattn-vec.cuh"
allreduce.cu|refused: template launch of ggml_cuda_ar_add_kernel<T_dst, T_src> depends on the template parameter
LIST
exit $fail
