# Path B IR passes (IR to IR)

`scripts/pathb-ir-opt.rb` runs passes on the mid-level IR text of `scripts/pathb-dump --ir`, so every back end that reads that
text can use them. It runs on the mruby subset that the emitters use (`scripts/mrb`).

    scripts/mrb scripts/pathb-ir-opt.rb --inline [--max-depth=N] [--report] FILE.ir > out.ir
    ruby scripts/pathb-ir-opt.rb [--prune-unreachable=SUBSTR] [--strip-eh] [--inline] [--sroa] [--jobs=N] [--forward] FILE.ir

## Inlining (`--inline`)

A statement `(let %D T (call T &"f" ARGS...))` or `(eval (call T &"f" ARGS...))` of a function of the module is replaced by
f's body:

- f's ids become fresh ids of the caller; its slots become caller slots named `NAME.iK` (K counts the inlinings of the module),
  hoisted after the caller's header;
- its parameters are bound to the arguments (the substitution puts the argument operand where the parameter is used);
- its final `(return X)` becomes `(let %D T X)`; the IR grammar allows a bare operand as an RVALUE, and the two emitters evaluate
  one (`tools/pathb-spirv-emit/emit.cpp` and `scripts/pathb-spirv-emit.rb`).

A callee with returns before its end is inlined as a loop that runs once (see "Early returns" below). Refused callees (counted by
`--report`): constructors and destructors, ellipsis parameters, struct or array results, struct or bool parameters, printf,
recursion, goto and label, an early return of a non-scalar, and work-group statics (the emitters key those by their function,
`wgs_layout`). Rounds repeat for nested calls, up to `--max-depth` (default 4, as the device inliner of `pathb-ptx-emit`).

The refusals of by-value structs matter most for SYCL: the kernel lambda takes its `nd_item` by value, so the kernel's frame keeps
that 72-byte copy, and the GPU time per launch does not change with inlining alone. Removing it needs scalar replacement of
aggregates (SROA), which is the next pass.

## Caps (`--max-callee`, `--max-growth`)

Each inlined copy is a full copy of the callee, and the callees grow with each round, so the output can grow by more than 30x
at the default depth (an 8.9 MB unit of libstdc++-heavy code went to 300 MB in 79 s). Two caps bound it:

- `--max-callee=N` (default 400 nodes): a callee bigger than N nodes is refused ("callee over --max-callee").
- `--max-growth=F` (default 2.0): once the module has grown to F times its size on entry, no further function is rewritten
  ("module over --max-growth").

The same unit with both caps: 16 MB, 3740 calls inlined, 3.8 s. 0 turns a cap off. The defaults are not tuned.

Known gap: after inlining, the SSA emitter (scripts/pathb-ssa-qbe.rb) refuses some functions of that unit ("let of $\"__j\""), so
`pathb-cc` falls back to the unoptimized IR for it. The pass is therefore not on by default.

## Use

**Path B host builds** (`scripts/pathb-cc`, the nfcxx driver's `NFCXX_PATH=b` and the default C++ route when Path B is chosen) run the
inliner by default. `-fno-inline` turns it off, and `-fir-opt-max=N` sets the largest IR it runs on (default 8388608 bytes; larger
units go unoptimized with a message). These are flags, not environment variables. The device passes below still read `NFCXX_IR_OPT`.

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

## Vulkan unroll cap (2026-11-06)

- The `groups` SYCL test (tests/sycl/groups.cpp) fails on lavapipe (`VK_ICD_FILENAMES=.../lvp_icd.json`) when the 13th counted-loop
  unroll is applied. That unroll is the one-iteration linear-id loop of `__nfcxx_sycl_entry_nd`. Float `reduce_over_group` returns 0 in
  the failing build. RADV and NVIDIA pass the same binary.
- Ruled out: the SSA and e-graph stages (the failure remains with them off), and the C++ and Ruby SPIR-V emitters (both fail). The
  two pass outputs are semantically equivalent, and both modules have the same 19 barriers and validate with `spirv-val`.
- Not a code-size effect: the 13th unroll removes 14 function-storage variables from `groups`, and the vecadd benchmark is unchanged.
- Workaround (`scripts/sycl-build.sh`, Vulkan default): `unroll-cap-in=nfcxx_sycl_entry,unroll-limit=12`. The cap counts only
  unrolls in entry kernels, so other functions keep their unrolls. A global cap was tried first and removed vecadd's unrolls, because
  earlier functions used up the count. `--unroll-min-trip=2` was also tried and removed the vecadd unrolls too.
- Verified on lavapipe: the full `tests/sycl/run.sh` Vulkan section passes (98 ok). The WebGPU section was skipped in that environment.
- Open: the root cause is unknown. Revisit the cap once the lavapipe or emitter cause is found.

## Early returns in loops and switches, wider unrolling (2026-11-09)

- **Early returns** (`expand_call`, `early_returns`): a callee whose returns are not all in tail position becomes
  `(loop (body STMTS... (break)) (step))`, and each return stores its operand to the slot `ret.iK` and breaks. A return inside a
  loop or switch of the callee was refused before ("return in a loop or switch"). Now it also stores true to a slot `done.iK`
  (bool, set to false before the one-trip loop), and after each loop or switch that holds such a return comes
  `(let %T bool (load bool $"done.iK")) (if %T (then (break)))`. Each break leaves one level, so control reaches the end of the
  one-trip loop. The tests go in the statement list that holds the loop or switch, so a `break` or `continue` of the callee keeps
  its C meaning (a `continue` in a switch continues the enclosing loop, a break in a switch leaves the switch).
- Check: `tests/pathb-ir-opt/return_in_loop.ir`, which has a return in a loop, in a nested loop, in a switch in a loop next to a
  `continue`, and in a loop in a switch of a void callee. After `--inline` and after `--inline --sroa`, `main` gives the results of
  the same functions compiled by gcc (`return_in_loop.args`) in both interpreters of `scripts/pathb-ssa.rb --run`. The inlined
  module also passes `tests/pathb-egraph/check.rb cases` (61 equal runs) and gives the same results after
  `pathb-ssa.rb | pathb-ssa-structurize.rb`.
- **Unrolling** (`try_unroll`): the test is any of `lt`/`le`/`gt`/`ge` (signed or unsigned), `eq` or `ne` of the counter and a
  constant, with the counter on either side (`0 < mask`). The counter may be `int`, `unsigned_int`, `long`, `unsigned_long` (and
  the `long_long` types). Its step may be `wadd`, `wsub`, `wmul`, `cshl` or `cshr` by a constant, as a let and a store or as one
  store of the expression. The trips are found by running the counter from its start value until the test fails (at most
  `UNROLL_MAX`, 4). A value that leaves the type's range, or a shift count outside `[0, width)`, refuses the loop. A loop of no
  trips becomes its test prefix, which the later passes drop. The test prefix also runs once after the last trip when it holds
  anything other than lets without a call. Two new checks make the unroller safer. The step's operation must use the value the
  step loaded. The counter slot must not be used other than as a load or store address (`unroll_escaped_slots`), so a store
  through a pointer cannot change it.
- On the mmvq kernels, the unroller refused these shapes before: `elem < 2` / `< 4` / `< 32` with `elem += 16` (unsigned long),
  the sub-group butterfly `for (mask = 8; 0 < mask; mask >>= 1)` (4 trips), `i < 1` on unsigned long, and `i = 1; i < 1` (no
  trips). All of them are unrolled now in the q4_0, q8_0 and q6_K `mul_mat_vec_q` kernels. What remains is the runtime
  `i < blocks_per_row` loop (`i += 8`) and the do-while loops of the half-to-float conversion (`man` normalisation, a data-
  dependent trip count).
- Check: `tests/pathb-ir-opt/unroll.ir`, where `main` matches gcc (`unroll.args`), five loop shapes are unrolled, and the loop whose
  counter is written through a pointer stays.

## Compile time (2026-11-09)

On the mmvq.cpp device IR (`raw.o.dev.ir`, 25 MB, 7366 functions) the passes took most of a 30-minute build, and with the early
returns inlined (above), the inline output grows from 226 MB to 672 MB. These changes keep the output text the same. That was
checked byte for byte on the inline output of the whole module, on `--sroa` of the q4_0, q8_0 and q6_K kernels, on the two
largest functions, on a 184-function sample of the inlined module, and with the tests.

- Inline (`inline_pass`): each function's largest id is kept per form (by identity) and computed again only for a rewritten
  function. A function with no call statement of a module function is not walked again. `max_id` reads the digits in place, and
  `refusal` reads its atoms and heads in one walk.
- Scalar replacement rounds (`sroa_pass`): the round's input is kept as a copy and compared form by form (`same_text?`). Before,
  two `show` texts of the whole function were built per round. A round whose result is its input ends the rounds, the first
  round too, because the next round would read the same text and give it again.
- `promote_address_slots`: the statements after each pointer store were walked again for each store, which is quadratic in a
  long list. Now one index per list (`suffix_index`) gives the uses after a position. The walk also skips forms with no pointer
  store inside.
- `fold_unit_index` memoizes the sets of each form (it walked every subtree once per enclosing level). `cprop_function`,
  `defined_values_ok?` and `unroll_escaped_slots` count in one walk without building the atom and form arrays.
- Output: `show_to` appends to one buffer per top-level form.
- Workers: the functions of `--sroa` are independent, so they are shared out by size among forked workers (`--jobs=N`,
  `NFCXX_IR_OPT_JOBS`, default: the processor count up to 8). Each worker sends back its functions' text. With
  `--unroll-limit` (a count across functions) the pass stays serial.
- Unreachable functions (`prune_pass`) are dropped before `--inline`, and again after it, from a SYCL device module.
  Such a module is one with functions named `__nfcxx_sycl_entry_`, which are the roots of all three emitters. The pass is
  on by default with `--inline` or `--sroa`. `--no-prune` keeps every function, and `--prune-unreachable=SUBSTR` names other
  roots. A function's `&"name"` atoms count as references, called or not. A global or data object is kept only when a reached
  function or object names it (`@"name"`, `$"name"`, `&"name"`): an object no reached code names is dead, and the functions only
  it names are dropped with it. (Before, every global and data form was a root: on `ggml-sycl.cpp` that kept 5354 of 9756
  functions, 23.6 MB of text, and `--inline` grew it to over 12 GB; now 290 functions and objects of 15308 are kept, and
  `--strip-eh --inline` takes 12 s with a 0.47 GB peak, the whole `--strip-eh --inline --sroa` 22 s with 0.54 GB.)
  The emitters only take what the entries reach, so the kernels are the same code. Their slot names (`.iK`)
  differ, because fewer calls are counted. On mmvq, 1693 of the 7366 functions are reachable before inlining and 564 after
  it. The inline output is 57 MB instead of 672 MB, and every later stage (SSA, e-graph, structurizer, emitter) reads it.
  Modules without SYCL entries (the tests, the CUDA paths) are unchanged.
- `SROA_ROUNDS` is 8 (was 4). An unrolled loop's copies are only walked in the next round, so a nest of loops unrolls one level per
  round. With more loops unrollable, 4 rounds left some mmvq entry kernels half unrolled: one had 282 loops and 44 aggregate
  slots, against 39 loops and none before. The rounds still end as soon as one changes nothing. Unrolling the copies in the same
  walk was tried too. It needed fewer rounds but left more aggregates (an int store and byte loads of one `sycl::vec<int,1>`
  that a later round would have split apart). On a 44-function sample of the pruned inlined module, against the old unroller:
  aggregate slots 339 against 346 (2208 against 2232 bytes), loops 366 against 491, text +12%, and only one function is
  worse (2 more loops). Time: 20.5 s with 8 workers against 182 s serial before.
- Measured on `exp/raw.o.dev.ir` with `--strip-eh --inline --sroa`. Before: the coordinator's run was killed after 139 minutes,
  and an inline-only run took 14:55. Now: 8:04 wall (2444 s of CPU across the workers) with a peak RSS of 1.6 GB per process.
  The output is 192 MB. Inline alone over every function (`--no-prune`) takes 7:10, against 13:19 before, and gives the same
  text.
