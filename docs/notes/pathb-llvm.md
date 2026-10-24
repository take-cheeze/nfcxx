# Path B from LLVM IR: `scripts/llvm-to-pathb.rb`

Status: **first slice, tested.** An LLVM IR text reader that writes nfcxx IR (`docs/notes/pathb-stage2.md`, section 6),
so LLVM IR from `clang -S -emit-llvm` goes through Path B's existing back ends: `scripts/pathb-qbe-emit.rb` (QBE),
`scripts/pathb-cil-emit.rb` (CIL), and `scripts/pathb-wasm-emit.rb` (WebAssembly: the wasm explorer's LLVM IR language,
`wasm-explorer.md`, also its Rust and Go through rustc's and TinyGo's LLVM IR). It is a second front end beside EDG. It does not use LLVM as a library, and it has no
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
REFUSED, not as a failure. Last run: 10 programs, all built and ran, 9 matched `EXPECT` and clang `-O0`, and the trap
case trapped (`arith`, `arrays`, `calls`, `control`, `floats`, `globals`, `opt1` (-O1: phi, select, the swap loop),
`structs` (nested, packed and named struct layouts, struct constants in globals, a struct memcpy), `unsigned`, and
`trap`). `structs.c` also gives 124 through the wasm emitter at `-O0`, `-O1` and `-O2`. The runner needs `build/qbe/qbe` (`scripts/setup-qbe.sh`) and `clang-18`. It is not in CI yet.

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
- Types: `i1` (bool), `i8`, `i16`, `i32`, `i64`, `float`, `double`, `ptr`, arrays, and structs: literal (`{ i32, ptr }`),
  packed (`<{ ... }>`) and named (`%T = type { ... }`, read before the functions). A struct is laid out by the x86-64
  data layout's rules (each field at the next multiple of its alignment, 1 when packed; the size rounded up to the
  largest alignment), and its IR type is a byte array: the IR reaches its fields by offset.
- Aggregate values in registers (first-class structs and arrays: TinyGo's strings and interfaces, rustc's pairs): each
  such register is a slot of the frame, and `insertvalue`, `extractvalue`, a `phi`, a `select`, a `load` and a `store`
  of one are copies. Within the module, an aggregate argument is passed as a pointer to the caller's value, and an
  aggregate result through a pointer to the caller's slot (a first parameter); a function of another module that takes
  or returns one is refused, since its convention is not known. A call through a function pointer takes the module's
  convention too (a trait object's method that returns a `&str`): a pointer can only hold the address of a function
  of this module, or of an external one without aggregates, since taking the address of an external function whose
  signature has one is refused.
- Globals: `external`, `internal`, `private`, `linkonce_odr`, `weak_odr`, `weak` (with the linkage markers of section 6);
  without an `align`, a global takes its type's alignment; initializers `zeroinitializer`, `undef`, scalar constants, `null`, function and global addresses, constant
  `getelementptr` (also of a `getelementptr`, and with struct indices), `inttoptr`, and arrays and structs of those
  (flattened to items at byte offsets; a `c"..."` inside a struct is bytes). A constant `[N x i8] c"..."` string becomes a
  `(data ...)` node. Debug metadata on a global (`, !dbg !5`) is ignored.
- Instructions: `alloca` (in the entry block a slot of the frame, which the wasm emitter's ASan mode checks; after it, a
  dynamic `alloca`), `load`, `store` (with `volatile`), integer `add sub mul sdiv srem udiv urem shl lshr ashr and or
  xor` (`and`, `or`, `xor` also on `i1`; `udiv` and `urem` are checked unsigned operations, which the wasm emitter takes
  and the QBE emitter refuses), `fadd fsub fmul fdiv fneg`, `icmp` (all ten predicates; pointers compare as unsigned
  longs), `fcmp` (all sixteen: `ord` is neither operand NaN, `one` ordered and unequal, each `u*` the negation of the
  opposite ordered predicate), `sext zext trunc sitofp fptosi fpext fptrunc ptrtoint inttoptr` (`trunc` to `i1` takes
  the low bit, `sext` from `i1` gives 0 or -1), `bitcast` of a pointer or between a float and an integer of its size,
  `getelementptr` (any number of indices into arrays and structs), `call` (direct and through a pointer, with
  `(variadic N)` for `...`), `select`, `phi`, `br`, `switch`, `ret`, `unreachable`, `freeze` (the value itself), and
  `extractvalue` and `insertvalue` (above).
- Intrinsics: `llvm.memcpy` and `llvm.memmove` (a `copy`, which has memmove's semantics) and `llvm.memset` of zero (a
  `zero-fill`), with a constant length or a run-time one (an `unsigned_long` register); `llvm.memset` of another byte
  and a constant length of at most 512 (stores of the byte repeated in a long); `llvm.fmuladd`, `llvm.smax`, `smin`,
  `umax`, `umin`, `llvm.abs`, `llvm.usub.sat`, `uadd.sat`, `llvm.ctlz`, `cttz` (a binary search over halves),
  `llvm.fshl`, `fshr`, `llvm.trap`, and `llvm.{s,u}{add,sub,mul}.with.overflow` (rustc's overflow checks: the
  `{ iN, i1 }` result is two registers, the wrapped value and the flag, which `extractvalue` reads). Hints are dropped:
  `llvm.lifetime.*`, `llvm.assume`, `llvm.experimental.noalias.scope.decl`, `llvm.dbg.*`, and `llvm.stacksave` and
  `stackrestore` (the dynamic allocas after a stacksave are released at the return instead).
- Calls and definitions may carry attributes (`noundef`, `noalias`, `range(i32 0, 10)`, `align 8`, ...) and the calling
  conventions `fastcc` and `ccc`, which mean nothing within one module; a `byval` or `sret` argument is refused.
- Names: quoted global and block names (`@"(*strings.Builder).String"`, `%"f[[]int].exit"`) may hold spaces and
  parentheses. Debug records (`#dbg_value`, LLVM 19) are skipped.
- Block order: the blocks are written in reverse post-order from the entry (unreachable ones last), so each register
  is declared before its uses in the text, as the QBE emitter needs; LLVM's own order does not promise it (rustc's
  `-Os` puts a returning block before the block that computes its value).

`--wasm` (the wasm explorer's Rust and Go): the IR is for a WebAssembly module, which runs on one thread and has no
operating system. The atomic operations (`load atomic`, `store atomic`, `cmpxchg`, `atomicrmw`, `fence`) become plain
loads and stores (`cmpxchg` gives the `{ T, i1 }` pair). An x86-64 `syscall` in inline assembly becomes a call of the
import `__syscall(nr, a1 .. a6)`, which the host answers. TinyGo's `setjmp` for `defer` (its inline `leaq 1f(%rip)`)
is 0, its first return: with `-panic=trap` nothing jumps back to it. A global `environ` that the module only declares
gets storage, an empty environment. Without `--wasm`, all of these are refused: a native program may have threads and
its own system calls.

## Refused, and why

These are gaps, not design decisions. Each is a `refused:` line, so a program that uses one is never miscompiled silently.

- **Aggregates across a module boundary**: an argument or result of struct or array type in a call of a function this
  module does not define (its convention is the target's ABI, which the `.ll` does not spell out).
- **`x86_fp80`** (`long double`), `half`, `fp128`, `i128`: the emitter has `long double` (`pathb-longdouble.md`), but the
  translator does not yet map `x86_fp80`.
- **Variable-length arrays** (`alloca` with a count): the emitter has `vlaalloc`; the translator does not yet map them.
- **`llvm.va_start`/`va_end`, `llvm.fabs`, `llvm.is.fpclass`, `llvm.ptrmask`**, other intrinsics, and `fptoui`.
- **Exceptions** (`invoke`, `landingpad`, `resume`: rustc's `-O0` code keeps them even with `panic=abort`), other inline
  assembly, vector types, `select` on vectors; atomics and `syscall` without `--wasm`.
- **Metadata** (`!dbg`, `!llvm.loop`) is ignored, which is correct: it does not change what the code does.

## Measured coverage

On the repository's own C files (the first 60 `.c` files of `git ls-files` outside `tests/macos*` and `tests/upstream`,
compiled by `clang-18 -O0 -S -emit-llvm`): 19 translate, 29 are refused and 12 do not compile for x86-64. The most
frequent refusals are variable-length allocas (8), `half` (4), `x86_fp80` and `fp128` (3 each); structs are no longer
among them. (An earlier run, on the list of that time, had 20 translated and 34 refused, 14 of them for structs.)
**The ones that translate are not run**:
only the programs in `tests/llvm-pathb/cases` are validated end to end. Running the rest needs their own main programs
and libraries; that is the next validation step.

Other front ends, beside `clang`: rustc (`--emit=llvm-ir -C opt-level=1`, a `#![no_std]` crate) and TinyGo (`tinygo
build -o prog.ll`, with `--wasm`) are the wasm explorer's Rust and Go (`wasm-explorer.md`). Their example programs, and
five more Rust programs (enums, slices, iterators, trait objects, function pointers, `-O1` and `-Os`, overflow checks on),
were checked through both back ends: the QBE binaries exit with the wasm modules' results, modulo 256.

## Next steps

1. `x86_fp80` through the emitter's long-double thunks (`pathb-longdouble.md`), `i128` through its existing lowering.
2. Wire `tests/llvm-pathb/run.sh` into `.github/workflows/pathb.yml` (it needs `clang-18`).
3. Validate the translated programs of a larger corpus, not only the cases.
