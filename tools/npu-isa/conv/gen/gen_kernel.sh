#!/bin/sh
# MLIR kernel (memref/affine, VPU.SW func form) -> typed LLVM IR for moviCompile.
# Usage: gen_kernel.sh <kernel.mlir> <out.ll>
# Stages: vpux-opt affine->LLVM, splice into the compiler's SW-module template (the adapt pass
# needs a runtime + main), vpux-opt adapt-LLVM-funcs-for-shave, then mlir2typed.py (act ABI).
set -e
K="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
VPUX="$HOME/openvino_git/bin/intel64/Release/vpux-opt"
TEMPLATE="$HOME/npu_compiler_git/tests/lit/NPU/ShaveCodeGen/adapt_llvm_funcs_for_shave_40XX+.mlir"
WORK="$(mktemp -d "$HERE/work.XXXX")"
trap 'rm -rf "$WORK"' EXIT

"$VPUX" --split-input-file --init-compiler="platform=NPU5010" --convert-Affine-to-LLVM --canonicalize "$K" > "$WORK/llvm.mlir"
python3 "$HERE/splice.py" "$TEMPLATE" "$WORK/llvm.mlir" "$WORK/spliced.mlir" >/dev/null
"$VPUX" --split-input-file --init-compiler="platform=NPU5010" --adapt-LLVM-funcs-for-shave "$WORK/spliced.mlir" > "$WORK/adapted.mlir"
python3 "$HERE/mlir2typed.py" "$WORK/adapted.mlir" "$OUT" act
