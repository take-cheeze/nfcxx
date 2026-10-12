#!/usr/bin/env bash
# CUDA's integer intrinsics that llama.cpp's ggml-cuda uses, through the nfcxx driver (device prelude in
# scripts/cuda-rewrite.rb, BUILTIN_DEFS; the emitter's SCALAR_U32 and WARP_SHUFFLES).
#   pass:    int.cu builds, links, runs on the GPU and checks every intrinsic against the CUDA definitions (0 mismatches).
#   pass:    half.cu and half_arith.cu: the 16-bit half type (conversions, __hadd, __hmul, __hfma) against CUDA host results.
#   pass:    half2.cu (the packed __half2 and its pair functions) and int8.cu (8-bit integers), against host results.
#   pass:    block.cu (__syncthreads_or, __reduce_add_sync, __threadfence_system, __nanosleep, __isnanf, __shfl_up_sync),
#            hmax.cu (__hmax) and math.cu (the float math and __dp4a, __ldg, __saturatef, __fdividef, within tolerances).
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: intrinsics: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out

pass() {  # pass FILE.cu EXPECTED-SUBSTRING
  local src=$1 want=$2 name run
  name=$(basename "$src" .cu)
  if "$root/nfcxx" -c -I"$cuda/include" "$src" -o "$out/$name.o" > "$out/$name.log" 2>&1 \
     && "$root/nfcxx" "$out/$name.o" -L"$cuda/lib64" -lcudart -o "$out/$name" >> "$out/$name.log" 2>&1 \
     && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$name") && [[ "$run" == *"$want"* ]]; then
    echo "pass $name: $run"
  else
    echo "FAIL $name"; grep -v "pragma\|NV_SILENCE\|^ *\^\|^ *$\|warning" "$out/$name.log" | head -5; fail=1
  fi
}

refuse() {  # refuse FILE.cu MESSAGE-SUBSTRING
  local src=$1 want=$2 name rc=0
  name=$(basename "$src" .cu)
  "$root/nfcxx" -c -I"$cuda/include" "$src" -o "$out/$name.o" > "$out/$name.log" 2>&1 || rc=$?
  if [ "$rc" = 3 ] && grep -q "$want" "$out/$name.log"; then
    echo "refused $name: $(grep -m1 "$want" "$out/$name.log" | cut -c1-160)"
  else
    echo "FAIL refused $name (exit $rc, expected 3 with: $want)"; fail=1
  fi
}

pass int.cu "intrinsics: no error, 0 mismatches"
pass half.cu "half: no error, 0 mismatches"
pass half_arith.cu "half arith: no error, 0 mismatches"
pass half2.cu "half2: no error, 0 mismatches"
pass int8.cu "int8: no error, 0 mismatches"
pass half2_forms.cu "half2 forms: no error, 0 mismatches"
pass block.cu "block: no error, 0 mismatches"
pass hmax.cu "hmax: no error, 0 mismatches"
pass math.cu "math: no error, 57344 checks, 0 mismatches"
pass votes_trap.cu "votes: no error, 0 mismatches"
pass minmax.cu "minmax: no error, 0 mismatches"
exit $fail
