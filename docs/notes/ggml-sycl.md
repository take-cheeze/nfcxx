# ggml-sycl as a testbed for the SYCL front end

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

## 3. Is the op self-contained?

No, at the include level. `fill.cpp` includes `fill.hpp` and `common.hpp`, and `common.hpp` brings in:

- `base.hpp`, `dpct/helper.hpp` (3782 lines), `ggml.h`, `ggml-impl.h`, `ggml-sycl.h`, `presets.hpp`, `type.hpp`,
  `sycl_hw.hpp`, `memtrace.hpp`, `common.hpp` itself (1070 lines), and `dnnl.hpp` (off in the reference build).
- `ggml_backend_sycl_context`, `dpct::queue_ptr`, `ggml_sycl_set_device`, `SYCL_CHECK`, `scope_op_debug_print`,
  `GGML_ABORT`.

Measured with the reference flags (`icpx ... -E -H`): `fill.cpp` pulls **762 unique headers** (3365 include lines) and
expands to **612,722 preprocessed lines**. By origin: 307 under oneAPI's `compiler/include`, 77 under `mkl`, 210 libstdc++, 10
ggml, 3 Level Zero. The preprocessed unit contains about 7000 `__attribute__`, about 2000 `__builtin_`, 138 `__int128`,
89 `_Float16`, 30 `__float128` and 80 `__asm__`. None of the SYCL- or clang-only markers (`__SYCL_DEVICE_ONLY__` is
host-pass-empty, `__clang__`, `__sycl_kernel`) appear in the host pass.

The kernel itself is self-contained. `fill_kernel<T>` (the template) and its launch are in `tests/gpu/ggml/fill_kernel.cpp`,
a verbatim copy with a host `main` in place of the backend context. It runs on the Arc B60 and matches the fill value over
2,069,793 elements with 0 guard writes (the `test_fill` shape 303x207x11x3):

```
device: Intel(R) Arc(TM) Pro B60 Graphics
mismatches: 0 of 2069793, guard writes: 0 of 64
```

## 4. What nfcxx's SYCL front end would need, ranked by how much it blocks

1. **The SYCL header closure** (blocks everything). `<sycl/sycl.hpp>` and the 762-header closure use clang extensions
   (`__attribute__`, `__builtin_*`, `__int128`, `_Float16`, `__float128`, `__asm__`) and templates EDG has to accept.
   Options: teach EDG the clang extensions, or give nfcxx its own minimal `lib/sycl/` headers that declare only what the
   kernels use (`queue`, `nd_range`, `nd_item`, `range`, `half`, `malloc_shared`). The second is the practical first step
   and matches the `lib/cuda/nfcxx_cuda.h` approach.
2. **The host API used by fill** (blocks the launch): `sycl::queue` with `parallel_for(nd_range<1>, lambda)` and `.wait()`,
   `sycl::malloc_device/malloc_shared/free`, and `memcpy`. These map onto the OpenCL launch the XPU tests already use
   (`tests/gpu/spirv/launch.c`), with USM pointers passed as kernel arguments.
3. **The device rewrite** (`scripts/sycl-rewrite.rb`): it handles `range<1>` with an id lambda only. The fill kernel needs
   `nd_range<1>` with `nd_item<1>` and `item.get_global_id(0)`; scalar captures (`k`, `value`: the rewrite does not detect
   them and would leave them undeclared); a `void *` capture cast with `static_cast`; and a **template kernel**
   `fill_kernel<T>` instantiated per element type. The last one is the same refusal the CUDA build of llama.cpp hits
   (`build/llama-build2.log`: "template launch of k_repeat_back<T> depends on the template parameter T of the enclosing
   template"), so the fix serves both paths.
4. **The backend context** (`ggml_backend_sycl_context`, `dpct::queue_ptr`, `SYCL_CHECK`, `GGML_ABORT`,
   `scope_op_debug_print`): needed only for the full op test through `test-backend-ops`. A standalone extraction does not
   need it.
5. **Level Zero, oneMKL, oneDNN headers**: needed by `common.hpp` through `GGML_SYCL_SUPPORT_LEVEL_ZERO_API`, and by the
   other ops. A reduced build (no Level Zero, no MKL, no dnnl) would remove most of the closure, if the rest of
   `common.hpp` still compiles without them.
6. **Subgroups, reductions, ESIMD, bfloat16, joint_matrix**: not used by fill. They block the norm and mul_mat ops
   (`sub_group` in 22 files, `reduce_over_group` in 5, `esimd` in 4).

## 5. Testbed, in order

1. Done: oneAPI vector-add (`tests/gpu/sycl/`), SPIR-V path verified on the XPU.
2. Done for the oracle: `tests/gpu/ggml/fill_kernel.cpp` (the F32 fill kernel and its `nd_range` launch) builds with
   `scripts/sycl-build.sh` and passes on the Arc B60 through both OpenCL and Level Zero (2,069,793 elements, 64 guard
   slots, the value + 1 mutant caught; `tests/gpu/ggml/run.sh`). The upstream subset already has `nd_range`, `nd_item`
   and the USM calls this needs, so the custom rewrite is not on this path.
3. Next: the real `fill.cpp` through nfcxx (its 762-header closure, and the template kernel `fill_kernel<T>` with a `void *`
   capture cast), then F16 (`sycl::half`), then the test_fill shape from `test-backend-ops`.
4. Then `diag` (F32, `diag.cpp`, 67 lines, `test_diag`), and the unary ops from `element_wise.cpp` (after the template
   and scalar-capture work).
5. Last: the whole `test-backend-ops` SYCL run, which needs the backend itself (the full `ggml-sycl.cpp`) built by nfcxx.
