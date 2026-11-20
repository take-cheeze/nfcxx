# Vectorized conv kernels

`conv_vec.py` emits hand-written LLVM IR with vector types, not MLIR. The MLIR `vector` dialect is not loaded in our
`vpux-opt`, but MoviCompile accepts `<8 x half>` loads, `fpext` to `<8 x float>`, `fmul`/`fadd` and stores when the
IR uses the same ABI as the typed relu kernel (`gen/relu_seed.ll` supplies the preamble and wrapper).

Kernel shape:
- 8 output channels per vector iteration. Weights are laid out `[i][kh][kw][o]` so those 8 values are contiguous.
- Reduction over i, kh, kw as nested loops, with the `<8 x float>` accumulator carried through phi nodes in
  registers. Integer division and per-iteration memory round trips are avoided (an earlier version with both was
  slower than the scalar kernel).
- Output is `(oh, ow, o)` and is transposed on the host.

Results on the test machine: the 64->64 3x3 layer takes about 0.18 s per launch including overhead, against 0.79 s
for the scalar kernel, with the same accuracy. All ResNet50 conv configurations in the test set match onnxruntime.

Entry points: `conv_vec_run.run_conv(x, W, B, stride, pad)` (same interface as `conv_npu.run_conv`).
Environment: `OPENVINO_BIN`, `CONV_VEC_CACHE` override the OpenVINO path and kernel cache.
