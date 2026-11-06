# Path B IR passes (IR to IR)

`scripts/pathb-ir-opt.rb` runs passes on the mid-level IR text of `scripts/pathb-dump --ir`, so every back end that reads that
text can use them. It runs on the mruby subset that the emitters use (`scripts/mrb`).

    scripts/mrb scripts/pathb-ir-opt.rb --inline [--max-depth=N] [--report] FILE.ir > out.ir

## Inlining (`--inline`)

A statement `(let %D T (call T &"f" ARGS...))` or `(eval (call T &"f" ARGS...))` of a function of the module is replaced by
f's body:

- f's ids become fresh ids of the caller; its slots become caller slots named `NAME.iK` (K counts the inlinings of the module),
  hoisted after the caller's header;
- its parameters are bound to the arguments (the substitution puts the argument operand where the parameter is used);
- its final `(return X)` becomes `(let %D T X)`; the IR grammar allows a bare operand as an RVALUE, and the two emitters evaluate
  one (`tools/pathb-spirv-emit/emit.cpp` and `scripts/pathb-spirv-emit.rb`).

A callee is inlined only when every return is in tail position. Refused callees (counted by `--report`): constructors and
destructors, sret, byval and ellipsis parameters, struct or array results, struct or bool parameters, printf, recursion, goto and
label, return not in tail position, and work-group statics (the emitters key those by their function, `wgs_layout`). Rounds
repeat for nested calls, up to `--max-depth` (default 4, as the device inliner of `pathb-ptx-emit`).

The refusals of by-value structs matter most for SYCL: the kernel lambda takes its `nd_item` by value, so the kernel's frame keeps
that 72-byte copy, and the GPU time per launch does not change with inlining alone. Removing it needs scalar replacement of
aggregates (SROA), which is the next pass.

## Use

`NFCXX_IR_OPT=inline` makes `scripts/sycl-build.sh` run the pass on the device IR before the SPIR-V emitter (any list of passes
separated by commas). Unset, the IR is unchanged.

Checks: `tests/pathb-ir-opt/run.sh` (the golden output for `tests/gpu/device/helper.ir`); the Vulkan SYCL programs of
`tests/sycl/run.sh` with `NFCXX_IR_OPT=inline` must give the same results as without it. On Radeon 8060S (RADV) all 26 programs of
the Vulkan list do, with 1158 to 1396 calls inlined in each of the nine programs counted (most of them in the library code the programs reach).

## Measured (vecadd, 2^20 floats, local 128, Radeon 8060S)

| | functions | calls | RADV instructions | GPU time per dispatch |
| --- | --- | --- | --- | --- |
| without | 17 | 23 | 779 | 2.06 ms |
| `--inline` | 3 | 2 | 582 | 2.06 ms |

Stores go up (365 against 263): the arguments of an inlined call are stored into its slots, and those scalars are Function
variables, which the driver promotes. The frame stays 96 bytes (the `byval` `nd_item`).

## Promotion

Promotion of scalar slots (`promote_slots` in the PTX emitter) is not an IR pass here: the SPIR-V emitter already keeps every
scalar slot whose address is never taken in a Function variable, and the driver promotes those. Migrating it would not change
the SPIR-V. The PTX emitter keeps its own promotion until the IR version is checked against its output.

## Next

1. Scalar replacement of aggregates: a struct slot (or a `byval` parameter copy) whose uses are constant-offset loads and stores
   becomes one scalar slot per field, so the `nd_item` stays out of the frame.
2. The PTX emitter: switch its device inliner to this pass once the output matches (llama.cpp's kernels need the same perf).

## byval sizes and scalar replacement (2026-11-05)

- The front end writes a `byval` parameter as `(byval TYPE SIZE ALIGN)` (be/nfcxx_ir.c). The goldens of `tests/pathb-ir` keep the
  form without the two numbers (`ir_norm` in `tests/pathb-ir/run.sh`, as for copy). Two cases of `tests/pathb-ir` (`fold_empty_sfinae`,
  `thread_local_init`) differ with the HEAD front end too, so they are the local EDG drift, not this change.
- `--inline` copies a `byval` argument into a slot of the caller (the size and alignment from the parameter), and binds the
  parameter to that slot's address.
- `--sroa` replaces struct slots whose objects are only read and written at constant offsets by one scalar slot per field. A copy
  between slots joins their groups; a pointer slot that holds a struct's address (the inlined callee's `this`) is promoted to that
  address first. A group is refused when a use is not modelled (a call argument, a stored address, nonnull, index), when fields
  overlap with different types, or when a copy out of the group does not cover every byte. A function whose rewrite would lose
  a definition is left as it was (checked by `defined_values_ok?`).
- Measured: the Vulkan suite is identical with `NFCXX_IR_OPT=inline,sroa`. The vecadd frame is still 144 bytes (the entry wrapper's
  `it` and the copies of it): 458 groups are refused for copies out that do not cover every byte, and some pointer chains remain.
- Next: complete the field coverage of a group that is copied out, with filler fields for the bytes no access reads (the bytes come
  from the copy in, so they are defined), which removes most of the refusals.

- Filler fields: a group that is copied out gets scalar fields for the bytes no access reads (the copy in gives them their values).
  A `nonnull` on an object's address is dropped with the object. The Vulkan suite matches the baseline with `inline,sroa`.
- Still open for the vecadd frame: the inlined `sycl::id` constructor zeroes its array with a dynamic index into the `nd_item`
  (`(index %p %i 8)` after `(bounds %i 1)`). A group with a dynamic index is refused, which is correct without more information. The
  next step is array scalar replacement: an index bounded by `(bounds %i N)` with a small N becomes a chain of constant-index accesses.

- `--sroa` first folds an index that a `(bounds I 1)` check has proved to be 0 into the base (`fold_unit_index`). The Vulkan suite
  still matches the baseline.
- What remains for the vecadd frame: the `sycl::id` copy in the entry wrapper indexes its array with a loop counter that the IR
  has no bounds check for (the loop runs over the template's dimension count, 1). Removing it needs loop-bound analysis
  (or unrolling a counted loop with a constant trip count) before the index is known.

## Analysis and unrolling (2026-11-05)

`--sroa` now runs these steps, in this order, on each function:

1. **Counted loops** (`unroll_list!`, `try_unroll`): the front end's `for` loop `(loop (body (let C ...) (if C (then) (else
   (break))) REST...) (step LOAD ADD STORE))`, with `C` = `counter < N` (constants), a counter that starts at a constant (the last
   store to it before the loop), a step of +1, no other store to the counter in the body, and no other break or continue, is
   replaced by its body and step, copied `N - K` times (at most 4) with fresh names per copy.
2. **Constant propagation** (`cprop_function`): a scalar slot whose uses are all plain loads and stores gives its loads the
   constant of the latest store in the same list. An arm or a block keeps what is known on entry; a loop or a switch keeps only
   what it does not store. A let that is a constant (or a `wadd`/`wsub`/`wmul` of two constants) is replaced in its uses; a
   register assigned with `set` is not a constant. An index by a constant is an offset of the base.
3. **Unit indexes** (`fold_unit_index`): after `(bounds I 1)`, `(index B I S)` is `B`.
4. **Scalar replacement** (as before), with copies of addresses as aliases and `nonnull` of a replaced object dropped.

Result on the vecadd benchmark (2^20 floats, RADV):

| | frame | RADV instructions | GPU time per dispatch |
| --- | --- | --- | --- |
| no passes | 96 bytes | 779 | 2.06 to 3.4 ms (noisy) |
| `inline,sroa` (now the default) | 16 bytes | 133 | 0.015 ms |

The GLSL reference, measured in the same session: 0.0126 ms per launch batched, 0.038 ms synchronous; ours is 0.052 ms
synchronous. The Vulkan suite (26 programs, RADV) is identical with the passes on, and `tests/pathb-ir-opt/run.sh` has golden
checks for `--inline` and for `--inline --sroa` on `helper.ir`.

`NFCXX_IR_OPT=off` turns the passes off in the SYCL device build; `--report` prints the refusal reasons, and the refusals of a
function whose rewrite would lose a definition are reported as such.

## Wider use (2026-11-05)

- **AMD `.cu` path** (`NFCXX_CUDA_TARGET=amdgpu`, `cu_amd_build` in the driver): the passes run on the device IR before
  `pathb-amdgpu-emit`, on by default. `NFCXX_IR_OPT=off` turns them off. `tests/cuda/amdgpu/run.sh` passes with them on and off. The
  compile sweep (`tests/cuda/amdgpu/sweep.sh`, 214 files) gives the same 155 ok / 23 refused / 36 fail with and without them, once
  `pathb-amdgpu-emit` accepts the bare-operand values that the passes create (`(let %D T %K)`, fixed in `main.cpp`).
- **Measured:** the `mul2` benchmark (2^26 ints, no structs) is the same with and without the passes, about 2.3 ms per launch and
  about 232 GB/s, which is the memory limit. The passes help code with struct locals and address chains, such as the SYCL kernels.
- **PTX path** (`cu_device_build`): the passes are wired in but opt-in (`NFCXX_IR_OPT=inline,sroa`). `pathb-ptx-emit` also accepts
  the bare-operand values now (`emit_fn.cpp`). The device goldens emit the same kernels with the passes on, but there is no NVIDIA
  GPU and no `ptxas` here, so the PTX output has not run; it stays opt-in until it has.
- **SYCL device build**: the default passes (`inline,sroa`) apply to every backend (Vulkan, OpenCL, Level Zero, WebGPU), since the
  device IR is shared. Only the Vulkan path has run here; the others need the Intel GPU or Chromium.

## NVIDIA RTX 5050 (sm_120), 2026-11-06

The GPU was not visible at first (the driver was not loaded then); `nvidia-smi` and `/usr/local/cuda-13.4` work now. The PTX
path runs here, so the passes were tested on it:

- **Suite:** `tests/cuda/run.sh` gives the same failures with the passes on and off (the golden-file failures of `device unit`
  predate this work). Only the `grid_sync_nobarrier` mutant's mismatch count differs, and it is caught in both runs.
- **Struct kernel** (`Pt` by value through two helpers, 2^24 threads): 4.97 ms per launch off, 2.96 ms on, same checksum.
- **mul2** (2^26 ints): 1.83 ms either way, 292 GB/s, the memory limit.
- The passes are on by default for the PTX device build now (`NFCXX_IR_OPT=off` turns them off).

Bugs found on the way and fixed:
1. `pathb-ptx-emit` refused the `(byval TYPE SIZE ALIGN)` form the front end writes (it wanted two items). A regression of the
   byval change; it accepts both forms now. `.version` is 8.7 for sm_100 and later (ptxas refused 8.0 for sm_120).
2. Constant propagation folded a value from a register that is assigned with `set` (a ternary) before it knew the register was
   assigned, so `(i == 5 ? 1 : tab[i & 7])` became 0 in every lane. Assigned registers are decided before the walk now.
3. Scalar replacement refused a group after it had merged it with another (the copy edges), so a slot passed by address to a call
   was replaced anyway. Refusals are applied after the merges now.
4. The driver's device-IR hook returned a failing status when its variable was unset, which stopped the build silently. Fixed.
