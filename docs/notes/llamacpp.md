# llama.cpp: ggml through nfcxx (CPU and CUDA backends)

`tests/llamacpp/run.sh` compiles llama.cpp's host-side ggml (ggml/src/*.c, *.cpp, and ggml-cpu/ with its tiled
sources) through the nfcxx driver on the gcc backend, and links `tests/llamacpp/ggml_cpu_check.c` (a small
`ggml_mul_mat` + `ggml_add` graph on the CPU backend, checked against a hand-computed result) against them. The clone
is `build/targets/llama.cpp` (`git clone --depth 1 https://github.com/ggml-org/llama.cpp.git`); the test skips without it.

## Result

- All 11 core files (`ggml.c`, `ggml-alloc.c`, `ggml-quants.c`, `ggml.cpp`, `ggml-backend*.cpp`, `gguf.cpp`,
  `ggml-opt.cpp`, `ggml-threading.cpp`) compile with the driver's C and C++ paths.
- The CPU backend (`ggml-cpu/*.c`, `*.cpp`, `tiled/*.cpp`) compiles with `-DGGML_CPU_GENERIC` and without the SSE
  predefines (see below): 23 objects in all.
- The check program links and runs (`ggml cpu check: ok`). The CUDA backend is in "CUDA backend" below.

## CUDA backend

`tests/llamacpp/cuda/build.sh` builds ggml with the CUDA backend (every `ggml-cuda/*.cu`, the template instances
included, with the default FlashAttention types of llama.cpp's CMake: f16-f16 only) and links llama.cpp's
`tests/test-backend-ops.cpp` against it, `-lcuda -lcublas -lcudart`: 214 objects, about 25 minutes at JOBS=2 under the
8 GB cap (objects are kept in `build/llcu`, so a second run only links). `tests/llamacpp/cuda/run.sh` runs each op of
`test-backend-ops test -b CUDA0` in its own process (a device fault aborts it) and checks it against its record. On the
RTX 2060 (sm_75, CUDA 13.1): 109 ops pass every case, 1 fails, 19 have no cases.

What it took (docs/notes/gpu.md, "Launch path", has the details):

- f16 conversions: the device `half` was an `unsigned short`, so `(float)h` was the integer value of the bits. Every
  f16 case of every op failed, and the quantized types too (their scales are f16). It is a struct now, as in cuda_fp16.h.
- Device-wide CUB (`sum`, `mean`, `argsort`, `top_k`, `cumsum`): `lib/cuda/cub/device.cu`, linked with `-lcudart`.
- `CUDART_VERSION` in the device pass: without it the host took CUB paths whose device code was the other branch
  (`cumsum_cub_kernel` trapped with `NO_DEVICE_CODE`). With it, the device pass also needs what CUDA 11.8+ code uses on
  sm_75: `movmatrix` asm (mma.cuh), `__nv_fp8_e4m3`, `__nv_cvt_e8m0_to_bf16raw` and `__nv_fp4x4_e2m1` (MXFP4).
- A kernel launched through a dispatch stub and also passed to `cudaFuncSetAttribute` (softmax, mmid) had only one of
  its two host addresses in the kernel table.
- The emitter lowers `__cxa_vec_ctor` and `memset` (arrays of mma tiles, whose half2 members are now constructed).
- A launch of a kernel with no device code was silent: the op left garbage and passed its CUDA_CHECK. It is reported
  through `cudaGetLastError` now, with the kernel's address in the program.
- binbcast.cu (ADD, SUB, MUL, DIV, REPEAT): `k_bin_bcast` is reached through `bin_bcast_cuda<op>::operator()` and
  `launch_bin_bcast_pack<op, ...>(..., std::make_index_sequence<n_fuse>{})`, whose calls give the rewriter no instance.
  The driver now builds such a unit twice: the host compile instantiates the kernels, and the second device rewrite
  takes their instances from the object's symbols (`nm -C`: 228 of them). binbcast.cu takes about 19 minutes instead
  of 6. The kernel's function parameter pack (`const src1_ptrs... src1s`) gives one entry parameter per element.
- The zero bytes of an aggregate initializer were stored as if the object were 8-byte aligned: mmvq's
  `float tmp[2][2] = {{0.0f}}` got an 8-byte store at 4 mod 8 (misaligned address, q4_0 MUL_MAT).
- The lanes of `nv_bfloat162` are bf16 values (they converted as integers), and `half2`/`nv_bfloat162` are 4-byte
  aligned (bf16 MUL_MAT, LIGHTNING_INDEXER).
- `cudaOccupancyMaxActiveBlocksPerMultiprocessor` and `cudaFuncGetAttributes` on a kernel's host address look the
  kernel up first, as `cudaFuncSetAttribute` does (FLASH_ATTN_EXT's launch_fattn: invalid resource handle).

- MUL_MAT and MUL_MAT_ID: the mmq kernels' "unspecified launch failure" was quantize_mmq_q8_1's float-to-integer
  trap, their illegal memory access the `ldmatrix` address (which also fixed CONV_2D and CONV_3D), mxfp4's
  misaligned address its kvalues table (an int8_t array read as uint32_t), the q1_0, q2_0 and FP4 values
  `__byte_perm`'s selector, and f16 with 8 columns mmvf's `half2 sumh2[8] = {{0.0f, 0.0f}}`, whose other elements
  were not zeroed (docs/notes/gpu.md).

Known failures (the KNOWN list of `run.sh`):

1. **FLASH_ATTN_EXT**: NaN for f16 K and V with hsk=40, then an unspecified launch failure.

## Flags

llama.cpp's CMake gives `_GNU_SOURCE` on Linux (`ggml-cpu.c` needs it for `CPU_ZERO`). The test passes it, plus
`-DGGML_CPU_GENERIC` for `ggml-cpu/` (the portable code in `arch-fallback.h`). For the C++ files it also removes
`__SSE__`, `__SSE2__`, `__SSE3__` and `__SSSE3__`: gcc defines them on every x86-64 host, and `ggml-cpu-impl.h` then
includes `immintrin.h`, which needs AVX10.2 builtins EDG does not know (below). The x86 SIMD paths are not exercised.

## Driver changes this needed

- `--emit-c` takes the first source from `srcs`, not `files[0]` (which can be an `-I` option).
- `-m*` (ISA and target options) are no longer passed to EDG as files (eccp rejects `-mavx2`). They go to the C
  compile (`--c_to_obj_option`), and the macros gcc predefines for them (`gcc -mavx2 -dM`, the difference from plain
  gcc) go to the front end as `-D` options.
- `-c` with only C sources stops at the object (it used to link). `-o` names the object; otherwise `<source>.o`.
- The gcc backend's C compiler is `scripts/gcc-cc`, which removes `#pragma GCC unroll` lines from EDG's generated C.
  libstdc++ 15's `__find_if` has the pragma, and EDG passes it through in front of a declaration, which gcc rejects
  ("for, while or do statement expected before 'auto'").

## Blockers (next list)

1. **EDG does not know GCC 15's AVX10.2 builtins.** Any C++ file that includes `<immintrin.h>` fails:
   `error: identifier "__builtin_ia32_vcvt2ps2phx256_mask" is undefined` (also `__builtin_ia32_vcvt2ph2bf8512_mask`).
   GCC 15's `immintrin.h` includes `avx10_2*intrin.h` unconditionally, and the `-512` variants share `immintrin.h`'s own
   include guard, so the driver cannot skip them. The fix is in EDG's builtin table, not the driver. Until then the
   x86 SIMD code of ggml-cpu (and any program using `immintrin.h`) does not compile.
2. **`C++ prelinker: warning: an error occurred during name decoding`** for `std::__cxx11::basic_string` symbols (about
   20 in the link). Harmless here, but it is a sign of a name-decoding gap.
3. **`--emit-c` takes no `-I`** (known, `docs/notes/realworld.md`): it cannot preprocess ggml's headers.

## Environment

The qbe backend fails the same way on `origin/main` in this checkout (`tests/cases/eh_exception_ptr.cpp`,
`eh_libstdcxx_throw.cpp`, `eval_order_calls.cpp`, `qbe_gnu_forms.cpp`, and five `tests/c` float128/float16/long double
cases: cproc rejects the qbe-prep output). These are not caused by the driver changes above; the gcc backend passes.
