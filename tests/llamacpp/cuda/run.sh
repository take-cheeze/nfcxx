#!/usr/bin/env bash
# llama.cpp's CUDA backend through the nfcxx driver, on the GPU: tests/llamacpp/cuda/build.sh builds ggml with
# ggml-cuda and links llama.cpp's test-backend-ops, which runs each op on CUDA0 and compares it with the CPU backend.
# Each op runs in its own process (a device fault aborts the process). The ops in PASS must pass every case; the ops
# in KNOWN fail now (docs/notes/llamacpp.md, "CUDA backend"), and one that passes fails the test, so the record gets
# updated. An op in neither list is reported and not checked.
# The build takes about 25 minutes at JOBS=2 (ggml-cuda.cu alone needs about 7.5 GB), so this is not in the default runs.
# Run it without an address-space limit (prlimit --as): CUDA reserves a large virtual range for its memory pool, and
# under the limit those ops fail with "out of memory". Cap the build instead (build.sh, the same OUT) and run this after.
# Env: OUT (build directory, default build/llcu; objects are kept there), and build.sh's LLAMA, CUDA_HOME, JOBS.
# Skips (exit 0, with the reason) without the llama.cpp clone, the CUDA headers or a GPU.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=${OUT:-$root/build/llcu}
command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 || { echo "SKIP: llamacpp cuda: no GPU"; exit 0; }
log=$("$root/tests/llamacpp/cuda/build.sh" "$out") || { echo "$log" | tail -5; exit 1; }
case $log in *SKIP:*) echo "$log"; exit 0 ;; esac
prog=$out/test-backend-ops

PASS="ABS ACC ADD ADD_ID ARANGE ARGMAX ARGSORT CEIL CLAMP COL2IM_1D CONCAT CONT CONV_2D CONV_2D_DW CONV_3D CONV_TRANSPOSE_1D
CONV_TRANSPOSE_2D COS COUNT_EQUAL CPY CROSS_ENTROPY_LOSS CROSS_ENTROPY_LOSS_BACK CUMSUM DIAG DIAG_MASK_INF DIV DSV4_HC_COMB
DSV4_HC_POST DSV4_HC_PRE DUP ELU EXP EXPM1 FILL FLASH_ATTN_EXT FLOOR GATED_DELTA_NET GATED_LINEAR_ATTN GEGLU GEGLU_ERF GEGLU_QUICK GELU
GELU_ERF GELU_QUICK GET_ROWS GET_ROWS_BACK GROUP_NORM HARDSIGMOID HARDSWISH IM2COL IM2COL_3D L2_NORM LEAKY_RELU LIGHTNING_INDEXER LOG MEAN
MUL MUL_MAT MUL_MAT_ID NEG NORM OPT_STEP_ADAMW OPT_STEP_SGD OUT_PROD PAD PAD_REFLECT_1D POOL_1D POOL_2D REGLU RELU REPEAT REPEAT_BACK RMS_NORM
RMS_NORM_BACK ROLL ROPE ROPE_BACK ROUND RWKV_WKV6 RWKV_WKV7 SCALE SET SET_ROWS SGN SIGMOID SILU SILU_BACK SIN SOFTPLUS
SOFT_MAX SOFT_MAX_BACK SOLVE_TRI SQR SQRT SSM_CONV SSM_SCAN STEP SUB SUM SUM_ROWS SWIGLU SWIGLU_CLAMP SWIGLU_OAI TANH
TIMESTEP_EMBEDDING TOP_K TRI TRUNC UPSCALE XIELU"
# op | why it fails now (see docs/notes/llamacpp.md)
KNOWN=""

fail=0
run_op() {  # run_op OP: res = "passed/total" ("" when the process died before its summary), err = the first error
  local op=$1 l=$out/ops/$1.log
  mkdir -p "$out/ops"
  # 40 minutes: FLASH_ATTN_EXT has 4004 cases and takes about 20 (RTX 2060, Ryzen 7 2700X)
  timeout 2400 "$prog" test -b CUDA0 -o "^$op\$" > "$l" 2>&1
  res=$(grep -oE '[0-9]+/[0-9]+ tests passed' "$l" | head -1 | cut -d' ' -f1)
  err=$(grep -m1 -oE 'CUDA error: [^/]*|no device code[^ ]*|Aborted' "$l")
}
for op in $PASS; do
  run_op "$op"
  if [ -n "$res" ] && [ "${res%/*}" = "${res#*/}" ]; then echo "ok   $op $res"
  else echo "FAIL $op ${res:--} $err"; fail=1; fi
done
while IFS='|' read -r op why; do
  [ -n "$op" ] || continue   # an empty KNOWN is one empty line
  run_op "$op"
  if [ -n "$res" ] && [ "${res%/*}" = "${res#*/}" ]; then echo "NOW PASSES $op $res: move it to PASS"; fail=1
  else echo "known $op ${res:--}: $why"; fi
done <<< "$KNOWN"
for op in $("$prog" --list-ops 2>/dev/null | awk '/^  [A-Z0-9_]+$/ {print $1}'); do
  case " $(echo $PASS) " in *" $op "*) continue ;; esac
  echo "$KNOWN" | grep -q "^$op|" && continue
  run_op "$op"
  [ "$res" = 0/0 ] || echo "unchecked $op ${res:--} $err"
done
exit $fail
