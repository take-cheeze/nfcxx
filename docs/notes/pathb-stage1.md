# Path B stage 1: harness and IL dump

Status: working for the eight `tests/cases/*.cpp` programs and for a wider probe program. It is a dump only:
nothing executes or links the IL yet.

## What was built

| File | Purpose |
| --- | --- |
| `be/nfcxx_be.c` | The back end. `back_end()` (called by `cfe.c` after lowering) walks the file-scope IL and prints it as s-expressions. |
| `be/nfcxx_be.h` | Output format (documentation) and the `back_end` declaration. |
| `be/nfcxx_names.h` | Name tables for EDG enumerations (operators, expression nodes, statements, dynamic-init kinds, constant kinds). Generated, see below. |
| `scripts/setup-pathb.sh` | Builds `cpfe` out of tree in `build/pathb` (about 1m45s on 4 cores with GCC 13). |
| `scripts/pathb-gen-names.sh` | Regenerates `be/nfcxx_names.h` from `3rd/edg/src/il_def.h`. |
| `scripts/pathb-dump` | Runs the harness front end on `file.cpp` from the EDG base dir (same flags as `nfcxx --emit-c`) and prints the IL. |
| `tests/pathb/<name>.il` | Golden dumps for each `tests/cases/<name>.cpp`. |
| `tests/pathb/run.sh` | Regenerates the dumps and diffs them against the goldens. `--update` rewrites the goldens. |

Commits on `wt/pathb`: back end and build (`580024a`), driver and goldens (`e43092a`), body-emission gate (`0c9c36a`).

Reproduce from a clean checkout (the submodule must be initialised):

```
scripts/setup-pathb.sh          # build/pathb/cmake/bin/cpfe
scripts/pathb-dump tests/cases/virtual_dispatch.cpp
tests/pathb/run.sh              # 8 cases, all must print "ok"
scripts/pathb-gen-names.sh      # only if EDG's enumerators change
```

## How the back-end switch works

Nothing under `3rd/edg` is modified. `setup-pathb.sh` makes `build/pathb/tree`, a view of the submodule in which
every entry is a symlink, except for three things:

1. `src/CMakeLists.txt`: in `CORE_FRONT_END_SOURCE_FILES`, `c_gen_be.c` is replaced by `nfcxx_be.c`. `c_gen_be.c` is not compiled.
2. `cmake/macro-conf/nfcxx-pathb/`: a macro configuration. `cpfe.cmakedef` sets `BACK_END_IS_C_GEN_BE=0`,
   `BACK_END_IS_CP_GEN_BE=0` and `DO_IL_LOWERING=1`, and imports the same `support/platform/linux/cpfe` and
   `support/build-type/release/cpfe` as `linux-gcc-release`. The configure step selects it with
   `-DEDG_MACRO_CONF=nfcxx-pathb`.
3. `src/nfcxx_be.{c,h}` and `src/nfcxx_names.h` are copies of `be/`.

Why this works: `cfe.c` calls `back_end()` whenever `BACK_END_SHOULD_BE_CALLED` is set. It declares
`extern void back_end(void)` itself when neither C-generating back end is selected. Lowering runs in the front end
(`fe_wrapup.c` -> `lower_il.c`), before that call, so `back_end()` sees the lowered IL. The base dir is
`build/pathb/edg-base`, copied from `bases/docker/dev-env/gcc`, with `include` pointed at `3rd/edg/include_c++`.

## IL coverage

Printed completely (no `(unsupported ...)`) for all eight test cases and a probe with `new`/`delete[]`, `dynamic_cast`,
`try`/`catch`, bit-fields, unions, lambdas, `goto`, `do`/`while`, `switch`, varargs, pointer-to-member and
member-function-pointer values:

- Routines: name (the linkage name), return type, parameters (plus `(ellipsis)` and `(static)`), body.
- Statements: `block` (with locals), `expr`, `if`, `while`, `do-while`, `for`, `switch`, `case`, `default`,
  `goto`, `label`, `return`, `decl`, `init` (kinds `constant`, `expression`, `constructor`), `empty`.
- Expressions: every `eok_*` operator as `(OP TYPE operands...)` (casts, calls, `dot_field`, `points_to_field`,
  `subscript`, assignments, `question`, `comma`, `land`/`lor`, ...), `const`, `var`, `routine`, `field`,
  `lifetime` (`enk_object_lifetime`).
- Constants: integers, floats (`fp_to_string`), strings, address constants (routine, variable, label, constant,
  temporary, with byte offset), aggregates.
- Types: integers (`bool` via `is_bool_type`), `void`, float kinds, pointers, arrays, function types, classes,
  structs, unions, `const`/`volatile`, `nullptr_t`.

Not covered (print `(unsupported ...)`):

- `stmk_asm` (inline asm), `stmk_set_vla_size` and `stmk_vla_decl` (VLAs), and the `enk_statement` expression (GNU
  statement expression `({ ... })`). All three appear in the probe, none in `tests/cases`.
- Constant kinds: `ck_dynamic_init`, `ck_init_repeat`, `ck_designator`, `ck_complex`, `ck_ptr_to_member` (not seen; only
  partly exercised).
- Global variable initializers: the dump shows `(global "name" TYPE)` only. File-scope dynamic initialization is not printed.

In the probe programs, `try`/`catch`, `throw`, `new`/`delete`, `dynamic_cast` and lambda construction were already
lowered before the back end (EH and runtime calls, aggregate initialization), so no node of those kinds reached it. I did
not check `typeid` or range-for.

## Surprises and things that do not work

- **Stock output omits routines the lowered IL keeps.** Comparing the routine name sets with the stock C generator
  (`--gen_c_file_name`, built in a scratch clone) over the eight cases: every routine the stock C defines is in the dump,
  and the dump has extra bodies. The extras are unreferenced inline or implicit members: `V::V()`, `W::W()`, `X::X()` in
  `virtual_dispatch`, `P::sum()` and the lambda call operator in `templates_lambdas`, and the `constexpr` function `fact`
  in `constexpr_static`. Two candidate rules did not explain the gap: `definition_needed`, which the reference
  `dump_routine_decl` also tests, and `suppress_inline_body`. The dump applies both, and the goldens did not change. The exact rule the
  C generator uses for these is not identified. Stage 2 should compute reachability itself (from `main`, non-inline
  globals, vtables and EH entry points) and check it against the stock names.
- **`BACK_END_IS_C_GEN_BE=0` changes more than the back end.** Several lowering paths test it: `lower_il.c` checks the
  vtable-pointer type size only under C-gen (line ~1471) and keeps tail-padded subobjects only under C-gen (line ~10023),
  and `ENSURE_LOWERED_TYPE_LIST_ORDERING` is tied to it (`host_envir.h`). The IL the harness sees may therefore differ
  from what the C generator sees. I did not diff the two IL trees. Both checks are cheap to compare against a stock IL dump,
  and the type-list ordering can be set explicitly in `cpfe.cmakedef`.
- **Standard headers are not available.** The EDG base ships only its own minimal `include_c++` (`*.stdh`, `typeinfo.h`,
  ...). `<cstdio>`, `<cstdarg>` and `<typeinfo>` fail to open, for the harness and for `nfcxx --emit-c` alike. The probe
  used `extern "C"` declarations and `__builtin_va_*`.
- **Relative `include` symlink dangles on copy.** The base's `include` is a relative link into the submodule. `cp -r`
  copies the link text, so from `build/pathb` it dangles. `setup-pathb.sh` replaces it with an absolute link. The stock
  `setup-edg.sh` copies the same way. I did not check the main checkout's `build/edg-base`, and I did not touch it.
- **cpfe writes `<stem>.ti` into its working directory**, which is the base dir. `pathb-dump` removes it after each run.
- **`-N` (`no_il_lowering`) does not give the unlowered C++ IL.** In this EDG `optk_write_unlowered_il` sets
  `suppress_back_end`, so `back_end()` is never called. The unlowered IL is not available without patching EDG's
  option handling in a copy. The design doc's "language-level IL for borrowing checks" therefore needs a further step.
- **No runtime.** `scripts/setup-edg.sh` also builds `eccp`, `edg_prelink` and `libC.a`. These need the C generator
  (`--gen_c_file_name` is compiled out here), so the harness builds `cpfe` only. Programs cannot be linked from this build.
- **Names are mangled.** Routine and vtable names are Itanium linkage names (`_Z3addii`, `_ZTV1V`). Source names are not
  printed. Temporaries print as `tmpN` and unnamed labels as `labelN`, numbered in order of first use within one dump, so
  goldens are stable (three consecutive runs produced identical output).
- **Front-end errors** exit with status 2 and produce no dump (EDG suppresses the back end). `pathb-dump` propagates
  the status.
- **Build flags.** cpfe is built with `-O3 -flto` and `-Werror=shadow`; the back end compiles cleanly under these.

## Verification

- `tests/pathb/run.sh`: all eight cases `ok`, zero `(unsupported` nodes.
- Clean clone (`git clone` of this branch, with `3rd/edg` pointed at the same submodule checkout): `scripts/setup-pathb.sh`
  succeeded in 1m44s and `tests/pathb/run.sh` passed.
- `3rd/edg` is unmodified: `git -C 3rd/edg status --short --ignored` is empty after both the harness and the stock
  build.
- Stock comparison (name sets as described above): no routine defined by the stock C output is missing from the dump.
- Probe programs (in the scratchpad, not committed): one C++ program without unsupported output, and one with VLA,
  statement expressions, complex and asm producing exactly the four unsupported kinds listed above.

## Recommendation for stage 2 (mid-level IR)

1. **Build the IR from the in-memory IL, in the back end.** `nfcxx_be.c` already has the complete walk. Keep the
   s-expression printer as the IR's text form and as the golden and Lean-side format, but do not parse it back. A second
   text round-trip would only add a failure point.
2. **Make the emitted routine set explicit.** Compute reachability from `main`, globals with initializers, vtables and EH
   entry points, and check the result against the stock C names for the eight cases. Document the rule in the IR spec.
   This removes the unreferenced constructor and inline bodies the dump currently shows.
3. **Structured control flow, typed three-address form.** Keep `block`, `if`, `while`/`do-while`, `for` and `switch` as
   regions, which is what GPU targets need. Keep `goto` and `label` as explicit control-flow nodes with a structurizer
   later. Flatten expression trees into typed instructions with explicit temporaries. EDG has already lowered `?:`,
   `&&`, `||` and `,` to `question`, `land`, `lor` and `comma`; make those control flow in the IR, not C expressions.
4. **Explicit UB policy at the operator level.** Split `add`/`subtract`/`multiply`/`negate`/`shiftl`/`shiftr` into a
   wrapping form and a checked form. Checked forms trap on signed overflow, division by zero, `INT_MIN / -1`, oversized
   shifts and float-to-int overflow. Use the existing tests (`signed_overflow_wraps`, `float_neg_switch`) as the first
   checks. Null checks belong on `points_to_field`, `indirect` and calls through pointers.
5. **Address arithmetic as operations.** `dot_field` becomes an offset from a base address, `subscript` and `padd` become
   `index(base, i, elem_size)`, and loads and stores carry the type. Layouts come from the EDG types, so sizes and offsets
   need not be recomputed.
6. **Close the gaps first, each with a diagnostic if not implemented.** Global initializers (file-scope dynamic inits)
   must be dumped before the IR can be complete. VLAs (`set_vla_size`, `vla_decl`), GNU statement expressions and inline
   asm should be rejected with a source position for now.
7. **Set the lowering options the IR needs in `cpfe.cmakedef` explicitly**, rather than inheriting C-gen defaults:
   `ENSURE_LOWERED_TYPE_LIST_ORDERING=1` and whatever the vtable and tail-padding checks need. Diff one or two programs
   against a stock C-gen IL dump before relying on it.
8. **Decide the unlowered-IL path now.** Borrowing and similar checks want the C++ IL. That needs either a patched copy of
   EDG's `cmd_line.c` option handling that keeps the back end, or a hook in `fe_wrapup`. It should be settled before the IR
   spec is frozen.

Open question for the team: stage 2 could run the IR builder as a separate step after the dump, or inside the back end.
Inside the back end is recommended, because the lowered IL is only in memory.
