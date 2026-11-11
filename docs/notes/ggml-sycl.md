# ggml-sycl as a testbed for the SYCL front end

Status (origin/main through PR #400, checked against the PR list): the real `fill.cpp` runs for F32 and F16 through the real
`libggml-sycl` on the Arc B60, and so does the real `diag.cpp`. The real `element_wise.cpp` (unary) is blocked in the device
emitter. `rms_norm` is a draft and does not run yet. `test-backend-ops`, BF16, `soft_max` and end-to-end runs are open.
Sections 4-8 are the status.

Source: `/home/takecheeze/dev/llm/llama.cpp` (ggml-sycl at `ggml/src/ggml-sycl/`, 46k lines in `.cpp`/`.hpp`/`.h`;
`tests/test-backend-ops.cpp`). The reference build is `build-sycl` (icpx 2026.1, `GGML_SYCL_TARGET=INTEL`, `GGML_SYCL_F16`,
`GGML_SYCL_DNNL=0`), whose `compile_commands.json` gives the flags used below.

## 1. What the SYCL backend uses

Counts are files containing the name (`grep -l`) and occurrences (`grep -o`), re-measured on the llama.cpp checkout above.

Headers: `<sycl/sycl.hpp>` (19 files), `<sycl/ext/oneapi/work_group_static.hpp>`, `<sycl/ext/oneapi/bfloat16.hpp>`,
`<sycl/ext/intel/esimd.hpp>` (ESIMD, 4 files), `<sycl/backend.hpp>`, `<level_zero/ze_api.h>` and `<level_zero/zes_api.h>`
(54 mentions of `ze_`), oneMKL, oneDNN (`dnnl.hpp`, off in the reference build).

Kernel API: `nd_item` 55 files / 602 uses, `nd_range` 51 files / 362, `sycl::half` 39 files / 718, `sub_group` 23 files / 413,
`reduce_over_group` 5 files / 10, `reqd_sub_group_size` 207 uses, `bfloat` 17 files / 122, `joint_matrix` 2 files / 12,
`esimd` 4 files / 96. Memory: `malloc_device`/`malloc_shared`/`malloc_host` (2 files), `sycl::free` (2 files), `memcpy` (1 file).
Not used: `sycl::buffer`, `sycl::accessor`, `host_task`, `kernel_bundle`, `SYCL_EXTERNAL`, `std::function`.

The kernels are `nd_item`-based, not `range`-based. Of the kernel launches, `nd_range` dominates `range` for anything with a
work group, and every elementwise op in `element_wise.cpp` is templated on the element type.

## 2. Ops the SYCL backend supports and test-backend-ops covers

`ggml-sycl.cpp` (`supports_op`) has 110 `case` labels (ops and unary sub-ops). The overlap with `test-backend-ops` (133 `test_*` structs) includes
ADD, SUB, MUL, DIV, LOG, UNARY (NEG, STEP, GELU, SILU, RELU, SIGMOID, EXP, ... ), NORM, RMS_NORM, SOFT_MAX, MUL_MAT,
SUM_ROWS, CLAMP, SCALE, SQR, SQRT, SIN, COS, ROPE, GET_ROWS, CONCAT, COUNT_EQUAL, FILL, DIAG, CUMSUM, ROLL, and more.

The smallest op: **FILL** (`fill.cpp`, 55 lines, F32 and F16 cases). `test-backend-ops` covers it with `test_fill`
(`tests/test-backend-ops.cpp`, the cases from line 11509, 3 F32 and 3 F16 shapes). Its F16 path needs `sycl::half`; its
F32 path needs only `nd_range<1>`, `nd_item<1>`, `get_global_id(0)` and `parallel_for`.

## 3. The fill op through nfcxx (done for F32 and F16)

`fill.cpp` includes `fill.hpp` and `common.hpp`, which bring in `dpct/helper.hpp`, `ggml.h`, `ggml-impl.h`, `ggml-sycl.h`,
`presets.hpp`, `type.hpp`, `sycl_hw.hpp`, and the backend context (`ggml_backend_sycl_context`, `SYCL_CHECK`, `GGML_ABORT`).
Measured with the reference flags (`icpx ... -E -H`): the closure is **762 unique headers** (3365 include lines), expanding to
**612,722 preprocessed lines**. By origin: 307 under oneAPI's `compiler/include`, 77 under `mkl`, 210 libstdc++, 10 ggml, 3 Level Zero.

`fill_real` (`tests/gpu/ggml/fill_real/`) compiles the real `fill.cpp` as its own TU, unchanged, through `scripts/sycl-build.sh`
and links it against the real `libggml-sycl.so` and `libggml-base.so` from the llama.cpp build. It runs on the Arc B60 over
2,069,793 elements with 64 guard slots. The test has three shims in place of the full closure, all in `lib/sycl-ggml/`:
`sycl/half_type.hpp` (a minimal `sycl::half`), `oneapi/mkl.hpp` (declarations of the oneMKL BLAS names `dpct` calls; not
implemented), and `sycl/info/aspects.def`. The link uses a version script (`local: *`) so the test executable's own dpct
helper copies do not interpose the library's (#355). `fill_real_f16` (#374) runs the F16 case of the same file the same way.

The fill oracle (`tests/gpu/ggml/fill_kernel.cpp`, a verbatim copy of the kernel and its `nd_range` launch, with a host `main`)
is the standalone check of the same kernel (#319, #327). It also matches the fill value with 0 guard writes:

```
device: Intel(R) Arc(TM) Pro B60 Graphics
mismatches: 0 of 2069793, guard writes: 0 of 64
```

## 4. Status by rung

| Rung | What | Status | PR | Where |
| --- | --- | --- | --- | --- |
| 1 | oneAPI vector add (SPIR-V through OpenCL and Level Zero on the Arc B60) | done | | `tests/sycl/vecadd.cpp` |
| 2a | fill, F32 oracle (standalone kernel copy) | done | #319, #327 | `tests/gpu/ggml/run.sh` |
| 2b | fill, F32, real `fill.cpp` through the real `libggml-sycl` | done | #355 | `tests/gpu/ggml/fill_real/` |
| 2c | fill, F16, real `fill.cpp` through the real `libggml-sycl` | done | #374 | `tests/gpu/ggml/fill_real_f16/` |
| 3a | diag, F32 oracle | done | #334 | `tests/gpu/ggml/diag/` |
| 3b | diag, real `diag.cpp` through the real `libggml-sycl` | done | #375 | `tests/gpu/ggml/diag_real/` |
| 4a | unary (neg, relu, silu, gelu; F32, flat and strided) oracle | done | #338 | `tests/gpu/ggml/unary/` |
| 4b | unary, real `element_wise.cpp` | blocked: the device emitter refuses it (`u2f` of bool, zero-initialized closure). Closure names fixed by #395 (merged); emitter fix #381 is an open draft; the test is #378 (draft) | #378, #381 | `tests/gpu/ggml/unary_real/` (fails at build) |
| 4c | `rms_norm`, F32 oracle with a warp reduction | not run: the `std::array` device gap is fixed by #400 (merged), but the real 16-lane sub-group reduction needs #401 (open). Test is a draft | #394, #401 | `tests/gpu/ggml/rms_norm/` on the #394 branch |
| 4d | `layer_norm` (GGML_OP_NORM), F32, real `norm.cpp` through the real `libggml-sycl`, rows of 64 and 1536 | blocked at the front end: `norm.cpp:18` (and `:19`, `:169`, `:170`), `error: no instance of function template "calculate_offset" matches the argument list` (`argument types are: ({...}, {...})`). The braced `std::array<int, N>` argument narrows `int64_t` strides. Reproducer: `tests/gpu/ggml/layer_norm/calc_offset_narrowing.cpp` (the int-stride control compiles) | | `tests/gpu/ggml/layer_norm/` (fails at build) |
| 4e | `group_norm` (GGML_OP_GROUP_NORM), F32, 4 groups, real `norm.cpp` | blocked at the same front-end error: `norm.cpp` is one TU and the `calculate_offset` calls of 4d are in it (`group_norm_f32` itself has none). Same reproducer | | `tests/gpu/ggml/group_norm/` (fails at build) |
| 5 | `test-backend-ops` SYCL run | not run (0 of 133 `test_*` cases) | | `tests/test-backend-ops.cpp` in llama.cpp |
| 6 | end-to-end `llama-bench` or `llama-cli` | not started | | |

## 5. Fixes that unblocked the real code

| PR | Fix |
| --- | --- |
| #343 | spirv: a shift count takes the width of the shifted value (dropped stores after a 64-bit multiply-high) |
| #330 | qbe-prep: lower GCC 14 type-generic bit builtins (`clzg`, `ctzg`, `popcountg`, `parityg`) |
| #329 | qbe-prep: rewrite a bare `return` in a non-void function (cproc rejects it) |
| #331 | QBE: keep a loaded-but-never-stored slot, in the fork (pin bump, no patch files) |
| #333 | sycl-build: `-l`, `-L`, `-Wl,*` and `-rpath` go to the host link only |
| #350 | sycl-build: user `-I` flags before `OPENCL_INCLUDE` on the OpenCL host compile |
| #342 | sycl runtime: split a dispatch into slabs when its stacks exceed the heap (OpenCL, Level Zero) |
| #351 | sycl Vulkan runtime: the same slab split |
| #355 | the real `libggml-sycl` linked; ODR fixed by a version script; `fill_real` added |
| #358 | `scripts/oneapi-env.sh`: the shared oneAPI runtime environment |
| #390 | `unary_real`: a mutant is caught only by a wrong result |
| #395 | closure names get one module id in the device pass and the host build |
| #400 | device pass lowers a local `std::array` (EH state and assert failure) |
| #401 (open) | sub-groups have 16 real lanes (OpenCL shuffles, SPV_INTEL_subgroups); needed by the `rms_norm` reduction |

## 6. Open gaps

1. **The header closure beyond fill.** `diag.cpp` and `element_wise.cpp` include `common.hpp` too, and the fill and diag tests
   still use the `lib/sycl-ggml/` shims. Removing them means the full `dpct/helper.hpp` and `common.hpp` closure compiles
   through nfcxx, with the `<sycl/sycl.hpp>` headers.
2. **BF16.** `bfloat16` (17 files, 122 uses) is not run for any op. F16 is run for fill only; the F16 paths of the other ops
   are not.
3. **Unary real code**: blocked on the emitter (#378, #381).
4. **Sub-group reductions for norm and `mul_mat`.** #401 (open) gives 16 lanes. `rms_norm` (#394) is not run. `mul_mat` is not
   started. ESIMD (4 files) and `joint_matrix` (2 files) are not used by any rung yet.
5. **`soft_max`**: not started.
6. **`test-backend-ops`**: not run. 0 of 133 cases. It needs the whole backend (`ggml-sycl.cpp`) built by nfcxx.
7. **End-to-end `llama-bench` or `llama-cli`**: not started.
8. **macOS `clzg` known failure.** `tests/builtins/bit_g.cpp` is marked `MACOS-XFAIL-qbe`: the EDG front end rejects
   `__builtin_clzg` with the Apple SDK headers. Not investigated yet.

## 7. How to run

Each script skips with exit 0 when a tool is missing (`spirv-val` or `spirv-as`, the OpenCL headers, `libOpenCL.so.1`, or a
GPU), and a backend whose runtime reports no device is skipped (exit 70). Each one also builds a mutant that must fail.

The oneAPI environment comes from `scripts/oneapi-env.sh` (merged in #358). Source it first. It sets `LD_LIBRARY_PATH` for the
compiler, MKL, TBB and UMF libraries and `OPENCL_INCLUDE`. It reads `ONEAPI_ROOT` (default `/opt/intel/oneapi`).

```
. scripts/oneapi-env.sh
export GGML_BUILD=/home/takecheeze/dev/llm/llama.cpp/build-sycl/bin      # libggml-sycl.so, libggml-base.so
export GGML_SRC=/home/takecheeze/dev/llm/llama.cpp/ggml/src/ggml-sycl    # the real .cpp sources
# export SPIRV_TOOLS_BIN=/path/to/spirv-tools/bin   # only when spirv-val is not on PATH

bash tests/sycl/run.sh                     # SYCL programs on host, OpenCL and Level Zero
bash tests/gpu/ggml/run.sh                 # fill oracle
bash tests/gpu/ggml/fill_real/run.sh       # real fill.cpp, F32
bash tests/gpu/ggml/fill_real_f16/run.sh   # real fill.cpp, F16
bash tests/gpu/ggml/diag_real/run.sh       # real diag.cpp, three shapes
bash tests/gpu/ggml/pad_real/run.sh        # real pad.cpp, five shapes
bash tests/gpu/ggml/sweep.sh               # the device pass of every ggml-sycl .cpp (no run): which TUs compile
bash tests/gpu/ggml/unary_real/run.sh      # real element_wise.cpp: fails at build until #381 lands
bash tests/gpu/ggml/rms_norm/run.sh        # only on the #394 branch, not main
```

Other env used by the real-code scripts: `ONEAPI_LIB` (oneAPI lib dirs; defaults to the compiler, MKL, TBB and UMF `lib` dirs
under `/opt/intel/oneapi`), `OPENCL_INCLUDE` (set by `oneapi-env.sh`). `tests/gpu/ggml/diag_real/run.sh` also reads
`SPIRV_TOOLS_BIN`.

- `tests/gpu/spirv/run.sh`: the SPIR-V vector add and loop on the XPU.

## 8. Environment

- The oneAPI runtime comes from `scripts/oneapi-env.sh`, which `sycl-build.sh` and the SYCL tests source. It computes the
  variables itself and does not source `setvars.sh`.
- SPIR-V tools: `SPIRV_TOOLS_BIN` or `PATH` (nixpkgs `spirv-tools`).
- Device: the name is printed by the test (`Intel(R) Arc(TM) Pro B60 Graphics`), read from the device, not hard-coded.
