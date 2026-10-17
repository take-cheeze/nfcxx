# ggml-sycl as a testbed for the SYCL front end

Status (origin/main, PRs through #358): F32 fill runs through the real `libggml-sycl` on the Arc B60; diag and unary have
standalone oracles; the real diag and unary code, F16, sub-group ops and `test-backend-ops` are open. Sections 4-8 are the status.

Source: `/home/takecheeze/dev/llm/llama.cpp` (ggml-sycl at `ggml/src/ggml-sycl/`, 46k lines in `.cpp`/`.hpp`/`.h`;
`tests/test-backend-ops.cpp`). The reference build is `build-sycl` (icpx 2026.1, `GGML_SYCL_TARGET=INTEL`, `GGML_SYCL_F16`,
`GGML_SYCL_DNNL=0`), whose `compile_commands.json` gives the flags used below.

## 1. What the SYCL backend uses

Counts are files containing the name (`grep -l`) and occurrences of `sycl::` names.

Headers: `<sycl/sycl.hpp>` (18 files), `<sycl/ext/oneapi/work_group_static.hpp>`, `<sycl/ext/oneapi/bfloat16.hpp>`,
`<sycl/ext/intel/esimd.hpp>` (ESIMD, 4 files), `<sycl/backend.hpp>`, `<level_zero/ze_api.h>` and `<level_zero/zes_api.h>`
(54 mentions of `ze_`), oneMKL, oneDNN (`dnnl.hpp`, off in the reference build).

Kernel API (occurrences): `nd_item` 54 files / 499, `nd_range` 50 files / 336, `parallel_for` 53 files, `submit(` 21,
`sycl::range` 41 files / 821, `sycl::half` 38 files / 676, `local_accessor` 17 files / 149, `sub_group` 22 files,
`reduce_over_group` 5 files, `reqd_sub_group_size` 207 uses, `get_global_id` 16 files, `sycl::exp/sqrt/fabs/sin` 13 files,
`bfloat` 15 files / 84, `atomic_ref` 2 files, `joint_matrix` 2 files, `single_task` 1 file, `sycl::event` 2 files.
Memory: `malloc_device`/`malloc_shared`/`malloc_host` (2 files), `sycl::free` (2 files), `memcpy` (1 file).
Not used: `sycl::buffer`, `sycl::accessor`, `host_task`, `kernel_bundle`, `SYCL_EXTERNAL`, `std::function`.

C++ features: templates (49 files), `constexpr` (41), `if constexpr` (17), lambdas (56), `std::mutex` (3).
The kernels are `nd_item`-based, not `range`-based. Of the kernel launches, `nd_range` (50 files) dominates `range` for
anything with a work group, and every elementwise op in `element_wise.cpp` is templated on the element type.

## 2. Ops the SYCL backend supports and test-backend-ops covers

`ggml-sycl.cpp` (`supports_op`) has 110 `case` labels (ops and unary sub-ops). The overlap with `test-backend-ops` (133 `test_*` structs) includes
ADD, SUB, MUL, DIV, LOG, UNARY (NEG, STEP, GELU, SILU, RELU, SIGMOID, EXP, ... ), NORM, RMS_NORM, SOFT_MAX, MUL_MAT,
SUM_ROWS, CLAMP, SCALE, SQR, SQRT, SIN, COS, ROPE, GET_ROWS, CONCAT, COUNT_EQUAL, FILL, DIAG, CUMSUM, ROLL, and more.

The smallest op: **FILL** (`fill.cpp`, 55 lines, F32 and F16 cases). `test-backend-ops` covers it with `test_fill`
(`tests/test-backend-ops.cpp`, the cases from line 11509, 3 F32 and 3 F16 shapes). Its F16 path needs `sycl::half`; its
F32 path needs only `nd_range<1>`, `nd_item<1>`, `get_global_id(0)` and `parallel_for`.

## 3. The fill op through nfcxx (done for F32)

`fill.cpp` includes `fill.hpp` and `common.hpp`, which bring in `dpct/helper.hpp`, `ggml.h`, `ggml-impl.h`, `ggml-sycl.h`,
`presets.hpp`, `type.hpp`, `sycl_hw.hpp`, and the backend context (`ggml_backend_sycl_context`, `SYCL_CHECK`, `GGML_ABORT`).
Measured with the reference flags (`icpx ... -E -H`): the closure is **762 unique headers** (3365 include lines), expanding to
**612,722 preprocessed lines**. By origin: 307 under oneAPI's `compiler/include`, 77 under `mkl`, 210 libstdc++, 10 ggml, 3 Level Zero.

`fill_real` (`tests/gpu/ggml/fill_real/`) compiles the real `fill.cpp` as its own TU, unchanged, through `scripts/sycl-build.sh`
and links it against the real `libggml-sycl.so` and `libggml-base.so` from the llama.cpp build. It runs on the Arc B60 over
2,069,793 elements with 64 guard slots. The test has three shims in place of the full closure, all in `lib/sycl-ggml/`:
`sycl/half_type.hpp` (a minimal `sycl::half`), `oneapi/mkl.hpp` (declarations of the oneMKL BLAS names `dpct` calls; not
implemented), and `sycl/info/aspects.def`. The link uses a version script (`local: *`) so the test executable's own dpct
helper copies do not interpose the library's (#355).

The fill oracle (`tests/gpu/ggml/fill_kernel.cpp`, a verbatim copy of the kernel and its `nd_range` launch, with a host `main`)
is the standalone check of the same kernel (#319, #327). It also matches the fill value with 0 guard writes:

```
device: Intel(R) Arc(TM) Pro B60 Graphics
mismatches: 0 of 2069793, guard writes: 0 of 64
```

## 4. Status by rung

| Rung | What | Status | Where |
| --- | --- | --- | --- |
| 1 | oneAPI vector add (SPIR-V through OpenCL and Level Zero on the Arc B60) | done | `tests/sycl/vecadd.cpp`, `tests/sycl/run.sh` |
| 2a | fill, F32 oracle (standalone kernel copy) | done | `tests/gpu/ggml/run.sh` (#319, #327) |
| 2b | fill, F32, real `fill.cpp` through the real `libggml-sycl` | done | `tests/gpu/ggml/fill_real/` (#355) |
| 2c | fill, F16 (`sycl::half`) | not started | |
| 3a | diag, F32 oracle | done | `tests/gpu/ggml/diag/` (#334) |
| 3b | diag, real `diag.cpp` | not started (no open PR) | |
| 4a | unary (neg, relu, silu, gelu; F32, flat and strided) oracle | done | `tests/gpu/ggml/unary/` (#338) |
| 4b | unary, real `element_wise.cpp` | not started (no open PR) | |
| 5 | `test-backend-ops` SYCL run | not run (0 of 133 `test_*` cases) | `tests/test-backend-ops.cpp` in llama.cpp |
| 6 | end-to-end `llama-bench` or `llama-cli` | not started | |

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

## 6. Open gaps

1. **The header closure beyond fill.** `diag.cpp` and `element_wise.cpp` include `common.hpp` too, and the fill test still
   uses the `lib/sycl-ggml/` shims. Removing them means the full `dpct/helper.hpp` and `common.hpp` closure compiles
   through nfcxx, with the `<sycl/sycl.hpp>` headers.
2. **F16 and BF16.** `sycl::half` (38 files, 676 uses), `bfloat16` (15 files). Fill F16 and the F16 paths of the other ops.
3. **Sub-group and reduction ops**, needed by the norms and `mul_mat`: `sub_group` (22 files), `reduce_over_group` (5 files),
   ESIMD (4 files), `joint_matrix` (2 files).
4. **`test-backend-ops`**: not run. 0 of 133 cases. It needs the whole backend (`ggml-sycl.cpp`) built by nfcxx.
5. **End-to-end `llama-bench` or `llama-cli`**: not started.

## 7. How to run

Each script skips with exit 0 when a tool is missing (`spirv-val` or `spirv-as`, the OpenCL headers, `libOpenCL.so.1`, or a
GPU), and a backend whose runtime reports no device is skipped (exit 70). Each one also builds a mutant that must fail.

- `tests/sycl/run.sh`: the SYCL programs on the host, OpenCL and Level Zero (`vecadd`, `mulhi`, `vulkan_slab`, ...).
- `tests/gpu/ggml/run.sh`: fill oracle, OpenCL and Level Zero.
- `tests/gpu/ggml/fill_real/run.sh`: real `fill.cpp`. Env: `GGML_BUILD` (the llama.cpp build bin dir with `libggml-sycl.so`
  and `libggml-base.so`), `GGML_SRC` (`ggml/src/ggml-sycl`), `ONEAPI_LIB`.
- `tests/gpu/ggml/diag/run.sh`: diag oracle, three shapes.
- `tests/gpu/ggml/unary/run.sh`: unary oracle, four ops, two shapes.
- `tests/gpu/spirv/run.sh`: the SPIR-V vector add and loop on the XPU.

## 8. Environment

- The oneAPI runtime (compiler, MKL, TBB, UMF libraries) comes from `scripts/oneapi-env.sh`, which `sycl-build.sh` and every
  test above source. It sets `LD_LIBRARY_PATH` and `OPENCL_INCLUDE` and does not source `setvars.sh`. Sourcing `setvars.sh`
  is refused by this environment's tool guard, so use `oneapi-env.sh` instead.
- SPIR-V tools: `SPIRV_TOOLS_BIN` or `PATH` (nixpkgs `spirv-tools`).
- Device: the name is printed by the test (`Intel(R) Arc(TM) Pro B60 Graphics`), read from the device, not hard-coded.
