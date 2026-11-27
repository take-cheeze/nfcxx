# MUL_MAT (iq4_xs) on CUDA: nfcxx against nvcc

Status notes for the slow `mul_mat_q` kernel that nfcxx builds for llama.cpp's CUDA backend. This records what was measured,
what was ruled out, and what was left. It is not a fix.

## The gap

llama.cpp `test-backend-ops`, MUL_MAT iq4_xs, 4096 x 512 x 14336, RTX 5050 (sm_120a):

| build | time | throughput |
|---|---|---|
| nvcc (`libggml-cuda.so`) | 1,592 us | 37.8 TFLOPS |
| nfcxx | 32,294 us | 1.86 TFLOPS |

That is about 20x. SOFT_MAX is less far apart: 524 us (nfcxx) against 369 us (nvcc), about 1.4x. The earlier ratios
recorded for these kernels (3.8x and 11.6x) were taken on other builds and are not reproduced here.

## Ruled out

**Always-on device checks.** The IR emits `(bounds)`, `(nonnull)`, and divide and shift checks in device code
(`be/nfcxx_ir.c`, `tools/pathb-ptx-emit/emit_fn.cpp`, `lower_arith.cpp`). The iq4_xs group g0000 has 105,703 `trap;`
lines. A pass that drops the provably safe ones removes 46,017 of them (to 59,686), but the compiled SASS is the same:
ptxas already removes almost all of these traps. The baseline cubin has 3,765 `BPT` traps, and the pass leaves that
count alone. Compile time is unchanged (178.5 s against 175.6 s, noise). The pass was not committed.

**Division checks.** The CUDA driver passes `--int=gpu`, so the zero-divisor and `-1` checks are not emitted in device
code. The signed-division path has no check in PTX.

**Register divisors.** The `--int=gpu` branch of `checked_div` (`tools/pathb-ptx-emit/lower_arith.cpp`) copies every
divisor into a register, including constants. g0000 had 90,633 `div`/`rem` with register divisors, and g0001 had
67,135. Emitting a nonzero immediate divisor directly leaves 60 and 260 of them, and cuts `mov` by about 7%. The SASS
does not change: g0000 is 824,432 instructions before and 824,440 after, and g0001 is 864,168 in both. ptxas already
folds the constant divisors. This change was not committed.

## What the iq4_xs kernel looks like

Per group, sm_120a, from `mmq-instance-iq4_xs.cu` (the build of the current worktree, without the register-divisor change):

| group | `mov` | `div`/`rem` | `trap` | `mma` | SASS instructions |
|---|---|---|---|---|---|
| g0000 | 1,319,600 | 90,633 | 172,078 | 3,882 | 824,432 |
| g0001 | 1,071,050 | 67,135 | 118,588 | 2,982 | 864,168 |

The PTX has tensor-core `mma` instructions, and there is no `dp4a` in the MMQ path. The SASS is large (about 0.8 M
instructions per group), and most of it is not the arithmetic. Two things stand out: the amount of register movement
that remains after ptxas, and the number of `mma` instructions relative to the number of loads.

## Not yet done

- An instruction-by-instruction comparison of nvcc's SASS for the same kernel. The symbol has to be found in
  `libggml-cuda.so` (sm_120a), then compared by instruction class (`HMMA`, `LDS`, `LDG`, `IMAD.MOV`, `BPT`) and by
  loop-body size.
- A timing run with the checks removed in the emitter, to bound what the checks could ever cost on hardware.

## Measurement

- Cubins: `cuobjdump -sass` on the group cubin, counting the lines that start with an address.
- PTX: `grep -c` on the group `.ptx` for each opcode family.
- Build: `tests/llamacpp/cuda/build.sh` with `NFCXX_SM` unset (the driver detects `120a` from `nvidia-smi`) and
  `NFCXX_CUDA_MAX_PTX_LINES=3000000` for this file.

See `docs/notes/gpu.md` for the GPU pipeline and the timing model.
