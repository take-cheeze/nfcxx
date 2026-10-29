#!/usr/bin/env bash
# The rewriter's refusals behind three of llama.cpp's single-file CUDA cases (see the files for the source forms):
#   softmax_deduced.cu   a deduced template argument in a launch (softmax.cu)
#   lightning_macro.cu   a launch inside a function-like macro (lightning-indexer.cu)
# Each must be refused with exit 3 and its message. Skips (exit 0) when the CUDA headers are missing.
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ]; then echo "SKIP: singles: needs cuda_runtime.h (CUDA_HOME)"; exit 0; fi
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
fail=0
check() {  # check FILE MESSAGE
  local rc=0
  "$root/nfcxx" -c -I"$cuda/include" "$1.cu" -o "$out/$1.o" > "$out/$1.log" 2>&1 || rc=$?
  if [ "$rc" = 3 ] && grep -qF "$2" "$out/$1.log"; then echo "refused $1: ok"
  else echo "FAIL $1: exit $rc, expected 3 with: $2"; fail=1; fi
}
check softmax_deduced "explicit arguments must give every template parameter"
check lightning_macro "launch without a kernel name"
exit $fail
