# Conv on the NPU through our own MLIR -> SHAVE route

`conv_npu.run_conv` computes a 2-D convolution on the Intel NPU 5000 with kernels we generate ourselves:
MLIR loop nest -> LLVM IR (`gen/gen_kernel.sh`, which uses Intel's `vpux-opt`) -> SHAVE ELF via MoviTools
(`gen/build.sh`, wine) -> patched into a one-input carrier blob that OpenVINO compiled for the same I/O size.
The DPU descriptors and weight layout are not involved.

## How it works

- Each launch covers a block of output rows (`ho_t`) and output channels (`cblk`). Its input is one flat fp16
  buffer: the padded input rows for the tile, the weight block, and the bias block, zero-padded to the carrier size.
- Launch sizes stay at or below 262144 elements. Larger single launches returned garbage in our tests.
- One kernel build serves every block of the same tile shape; weights and bias are data.
- Products and sums are f32; each output is truncated to f16.
- Kernels are cached under `~/conv-npu-cache`. OpenVINO is expected at `~/openvino_git/bin/intel64/Release` and the
  level-zero loader at `~/ze-loader/lib`; these paths are hardcoded in `conv_npu.py` and should be made configurable.

## Results

Checked against onnxruntime (fp16 rounding; maximum absolute difference at most about 0.02 on references of
magnitude 4 to 36): every ResNet50 Conv configuration in our test set, including the stem (7x7 stride 2) and the
stride-2 3x3 convs.

## Requirements

- Intel's `vpux-opt` (`$HOME/openvino_git/bin/intel64/Release`) and the NPU compiler tests used by `gen/gen_kernel.sh`.
- MoviTools under `~/.wine-movi` (`moviCompile64.dll`, `moviLLD64.dll`), run through wine; see `tools/npu-isa/README.md`.
- OpenVINO's `compile_tool` (to compile the one-input carrier blobs) and its Python package (in-process launches),
  and the NPU level-zero loader on `LD_LIBRARY_PATH`. The loader must be newer than the driver's requirement;
  a 1.28 system loader failed with `UNSUPPORTED_VERSION` on this machine.
- Python 3 with numpy, onnx and onnxruntime, and the OpenVINO Python package for in-process launches.

`gen/build.sh` also calls `mkext.py` and `patch_raw.py` in this folder.

## Known limits

- Speed: naive scalar SHAVE loops. A full ResNet50 pass takes about a minute, and nearly all of it is kernel compute.
  Vectorizing the kernels is the next step.
- The `Abs` carrier is used because it has a large enough `shave.text` slot. `Neg` produced garbage for this kernel.

## Files

- `conv_npu.py`: tiling planner, MLIR generator, kernel build, in-process launches, `run_conv`.
- `test_conv_npu.py`: checks `run_conv` against onnxruntime for given configurations.
- `gen/`: `gen_kernel.sh`, `build.sh`, `splice.py`, `mlir2typed.py`, `mkext.py`, `patch_raw.py`.
