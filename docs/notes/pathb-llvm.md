# Path B from LLVM IR: `scripts/llvm-to-pathb.rb`

Status: **first slice, tested.** An LLVM IR text reader that writes nfcxx IR (`docs/notes/pathb-stage2.md`, section 6),
so LLVM IR from `clang -S -emit-llvm` goes through Path B's existing back ends: `scripts/pathb-qbe-emit.rb` (QBE),
`scripts/pathb-cil-emit.rb` (CIL), and `scripts/pathb-wasm-emit.rb` (WebAssembly: the wasm explorer's LLVM IR language,
`wasm-explorer.md`). It is a second front end beside EDG. It does not use LLVM as a library, and it has no
LLVM build dependency. `clang-18` is only the source of the test inputs and the reference results.

```
prog.c --clang-18 -O0 -S -emit-llvm--> prog.ll --scripts/llvm-to-pathb.rb--> prog.ir
prog.ir --scripts/pathb-qbe-emit.rb--> prog.ssa --qbe--> prog.s --cc--> prog
```

Run: `scripts/mrb scripts/llvm-to-pathb.rb FILE.ll > FILE.ir` (exit 0 translated, 3 refused with `refused: ...` on
stderr, 1 malformed input). The translator is written in the subset of Ruby the mruby tool runs, like the other scripts.

Tests: `tests/llvm-pathb/run.sh`. Each `tests/llvm-pathb/cases/*.c` is compiled by clang-18 (`-O0`, or `-O1` with
`// OPT: 1`), translated, emitted, linked and run. Its exit code must equal the `// EXPECT:` value and the clang `-O0` binary
of the same source. `// TRAP: 1` programs must die with SIGABRT. A construct the subset refuses is reported as
REFUSED, not as a failure. Last run: 9 programs, all built and ran, 8 matched `EXPECT` and clang `-O0`, and the trap
case trapped (`arith`, `arrays`, `calls`, `control`, `floats`, `globals`, `opt1` (-O1: phi, select, the swap loop),
`unsigned`, and `trap`). The runner needs `build/qbe/qbe` (`scripts/setup-qbe.sh`) and `clang-18`. It is not in CI yet.

## Policy decisions

These are the choices the subset makes where LLVM IR leaves room. A choice is recorded here, not made silently.

1. **`nsw` is checked.** `add nsw`, `sub nsw` and `mul nsw` become `cadd`, `csub` and `cmul`, which trap on overflow.
   LLVM says overflow is poison, so trapping is a valid refinement. This is the default the design asks for.
   `nuw` and the other wrapping forms become `wadd`, `wsub`, `wmul`, which is also a valid refinement of poison.
2. **Shifts are checked.** `shl` becomes `cshl`, `lshr` and `ashr` become `cshr` (unsigned or signed type). A count out
   of range is poison in LLVM, so the trap is again a valid refinement. `exact` on `sdiv`/`lshr` is dropped.
3. **`undef` reads as zero.** A `poison` operand is also read as zero, not rejected, because a checked operation
   has already trapped where poison would have been produced.
4. **`inbounds` is not checked.** The IR has no length for a pointer, so an out-of-bounds `getelementptr` is not caught.
   This is the same gap as pointer subscripts in stage 3 (`pathb-stage3.md`, "Known gaps").
5. **Floating point.** `une` is `ne` (C's `!=`, true on NaN) and `olt` and the other ordered predicates are `lt.f` and
   `le.f`, with the operands swapped for `ogt` and `oge`. These match C, and `tests/llvm-pathb/cases/floats.c` checks NaN.
   `llvm.fmuladd` is `fmul` then `fadd`: LLVM allows the fused form but does not require it.
6. **Signedness.** The IR's integers are signed. A zero extension is the sign extension masked to the source width, so
   no register is ever declared unsigned. Unsigned comparisons (`lt.u`) and unsigned shifts take their type from the
   operation.
7. **Allocas.** Each `alloca` in the entry block is `(alloca (const int N))`, a dynamic stack allocation that lives until
   return. Registers are the stack slots that QBE promotes, as in every Path B program.
8. **Control flow.** The CFG is emitted with `goto` and `label`, the IR's fallback form, so no structurizer is needed for
   QBE. `phi` nodes are stack slots set on each incoming edge. When one block has several phis, every source is copied to
   a temporary first, so a phi that reads another phi of the same block sees the old value (the `swap` case in
   `opt1.c`). `select` is a conditional `set`. `switch` is a chain of compares in table order.
9. **Symbols.** LLVM's private names with a leading dot (`.str`) are spelled `llvm.str`, because a QBE identifier does not
   start with a dot. The rename applies everywhere the name is spelled.

## What is in the subset

- Module: `source_filename`, a 64-bit target triple, globals and functions. Top-level `module asm` is refused.
- Types: `i1` (bool), `i8`, `i16`, `i32`, `i64`, `float`, `double`, `ptr`, and arrays of those (nested to any depth in
  initializers and `getelementptr`).
- Globals: `external`, `internal`, `private`, `linkonce_odr`, `weak_odr`, `weak` (with the linkage markers of section 6);
  initializers `zeroinitializer`, scalar constants, `null`, function and global addresses, constant `getelementptr`,
  and arrays of those (flattened to items at byte offsets). Private `c"..."` strings become `(data ...)` nodes.
- Instructions: `alloca`, `load`, `store` (with `volatile`), integer `add sub mul sdiv srem shl lshr ashr and or xor`
  (`and`, `or`, `xor` also on `i1`), `fadd fsub fmul fdiv fneg`, `icmp` (all ten predicates; pointers compare as
  unsigned longs), `fcmp` (`oeq une olt ole ogt oge`), `sext zext trunc sitofp fptosi fpext fptrunc ptrtoint inttoptr`,
  pointer `bitcast`, `getelementptr` (any number of indices into arrays), `call` (direct and through a pointer, with
  `(variadic N)` for `...`), `select`, `phi`, `br`, `switch`, `ret`, `unreachable`.
- Intrinsics: `llvm.memcpy` with a constant length (a `copy`), `llvm.memset` of zero (a `zero-fill`), `llvm.fmuladd`,
  `llvm.smax`, `smin`, `umax`, `umin`.
- Calls may carry return-value and argument attributes (`noundef`, `noalias`, ...); a `byval` or `sret` argument is refused.

## Refused, and why

These are gaps, not design decisions. Each is a `refused:` line, so a program that uses one is never miscompiled silently.

- **Structs** (`%struct.*`, literal `{ ... }` types, and GEPs into them): the struct layout is not in the `.ll`
  text; the IR's `(offset ...)` needs the field offsets. The next big step.
- **`x86_fp80`** (`long double`), `half`, `fp128`, `i128`: the emitter has `long double` (`pathb-longdouble.md`), but the
  translator does not yet map `x86_fp80`.
- **Variable-length arrays** (`llvm.stacksave`, `llvm.stackrestore`, `alloca` with a count): the emitter has
  `vlaalloc`; the translator does not yet map them.
- **`udiv`, `urem`**: the emitter refuses checked unsigned operations, so there is no checked form to map to yet.
- **`llvm.va_start`/`va_end`, `llvm.fabs`, `llvm.is.fpclass`, `llvm.ptrmask`**, other intrinsics.
- **Exceptions** (`invoke`, `landingpad`), inline asm, vector types, atomics, `select` on vectors, `freeze`,
  `extractvalue`/`insertvalue`: not in the subset.
- **Metadata** (`!dbg`, `!llvm.loop`) is ignored, which is correct: it does not change what the code does.

## Measured coverage

On the repository's own C files (the first 60 `.c` files outside `tests/macos*` and `tests/upstream`, compiled by
`clang-18 -O0 -S -emit-llvm`; 6 do not compile for x86-64 at all: Hexagon assembly fixtures and deliberately malformed
`tests/mruby/strip-atomic` inputs): 20 translate and 34 are refused, for the reasons above (the most frequent: structs 14,
`x86_fp80` 7, stack save 5). **The 20 that translate are not run**:
only the programs in `tests/llvm-pathb/cases` are validated end to end. Running the rest needs their own main programs
and libraries; that is the next validation step.

## Next steps

1. Structs: layouts from the `%struct` definitions (fields at their offsets, with the same rules as the IR's
   `(layout ...)`), then GEPs with a struct index as `(offset ...)`.
2. `x86_fp80` through the emitter's long-double thunks (`pathb-longdouble.md`), `i128` through its existing lowering.
3. Wire `tests/llvm-pathb/run.sh` into `.github/workflows/pathb.yml` (it needs `clang-18`).
4. Validate the translated programs of a larger corpus, not only the cases.
