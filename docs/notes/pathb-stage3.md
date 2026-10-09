# Path B stage 3: IR global initializers and the IR-to-QBE emitter

Stage 3 adds the first consumer of the IR. Its spec is in `docs/notes/pathb-stage2.md` (sections 6-7);
this note records what stage 3 covers, what it refuses, and the results.

## What changed

- **Global initializers in the IR** (`be/nfcxx_ir.c`). A global prints as
  `(global NAME TYPE BYTES ALIGN [(static)] INIT)`, where INIT is `(extern)`, `(init ITEM*)` or
  `(unsupported ...)`. Items are `scalar`, `addr`, `bytes` and `zero`, in the element order of
  `ir_init_constant`. Function-local statics take their initializer from EDG's
  `get_variable_initializer`. Slots print their size and alignment. Stage 2's `vtables are empty` gap is closed.
- **Fixes in the lowering:** `!` on a comparison no longer dereferences NULL; casts from `bool` are lowered;
  a value-less `return` in a non-void, non-`main` function lowers to `(unreachable)`.
- **Template instances:** `pathb-dump` passes `-tused`, as `eccp` does for one file, so templates used by a
  file are defined (`templates_lambdas` links).
- **The emitter** (`scripts/pathb-qbe-emit.rb`, an mruby script; run it with `scripts/mrb`) reads the IR text and writes QBE IL.
- **Second round:** `(continue)`, a `(layout ...)` header, bool-load normalisation, reachability and `setjmp` (see
  Closed gaps below).

## The emitter

- Every IR register is a stack slot (`alloc` in `@start`). QBE's own promotion turns them back into SSA
  temporaries, so the emitter does not need dominance information for the IR's mutable registers.
- Slots and globals carry the byte size and alignment printed by the IR.
- Structured `if`, loops and `switch` become blocks and jumps. `switch` case markers may sit in nested
  blocks; they are dispatched by a compare chain with fallthrough.
- Checked operations (`cdiv`, `crem`, `cshl`, `cshr`, `cf2i`, bounds, nonnull, unreachable, and
  `cadd`/`csub`/`cmul`/`cneg` in trap mode) compare and jump to one shared `@abort` block that calls `abort()`.
- Integer constants may be hexadecimal.

### Refusals (exit 3, `refused: <reason>`)

Anything the emitter does not handle is refused, never dropped silently:

- volatile loads and stores;
- `long double`;
- variable-length arrays and the other unsupported IR markers (VLA statements, inline asm, bit-fields,
  statement expressions, constructor initializers);
- checked unsigned operations;
- checked 64-bit multiplication;
- a non-integer `switch`;
- non-finite float constants;
- global initializers that are dynamic or binding.

A malformed or older IR format exits 1.

## Translation validation

`tests/pathb-qbe/run.sh` builds each program with the stage 3 harness, emits QBE, assembles, links the way
`eccp` does, and runs it. The exit code must equal the `// EXPECT:` value, and the gcc backend must agree.
The runners skip `tests/cases/qbe_*.cpp`: those are production-path tests that need system headers and GNU forms the Path B harness does not have.
Trap programs must abort with `SIGABRT`; gcc is not compared for them, because C leaves those cases undefined.

Last run (on `main` at the time of writing):

```
28 programs: 28 built, 28 ran, 17 match EXPECT, 11 trapped as required, 0 refused, 0 failed
```

(That is the first round. The second round adds `continue`, `bool_load`, `reachability` and `setjmp`; 32 programs, see below.)

| Program | Result |
| --- | --- |
| `tests/pathb-qbe/cases/arith.cpp` | exit 14 = EXPECT 14 |
| `tests/pathb-qbe/cases/calls.cpp` | exit 94 = EXPECT 94 |
| `tests/pathb-qbe/cases/control.cpp` | exit 237 = EXPECT 237 |
| `tests/pathb-qbe/cases/floats.cpp` | exit 13 = EXPECT 13 |
| `tests/pathb-qbe/cases/globals.cpp` | exit 21 = EXPECT 21 |
| `tests/pathb-qbe/cases/variadic.cpp` | exit 0 = EXPECT 0 |
| `tests/pathb-qbe/multi/comdat/` (2 units) | exit 54 = EXPECT 54 |
| `tests/cases/constexpr_static.cpp` | exit 120 = EXPECT 120 |
| `tests/cases/exceptions.cpp` | exit 15 = EXPECT 15 |
| `tests/cases/float_neg_switch.cpp` | exit 42 = EXPECT 42 |
| `tests/cases/hvx_add_i16.cpp` | exit 67 = EXPECT 67 |
| `tests/cases/hvx_mul_i16.cpp` | exit 184 = EXPECT 184 |
| `tests/cases/raii_templates_class.cpp` | exit 7 = EXPECT 7 |
| `tests/cases/signed_overflow_wraps.cpp` | exit 1 = EXPECT 1 |
| `tests/cases/struct_libc.cpp` | exit 9 = EXPECT 9 |
| `tests/cases/templates_lambdas.cpp` | exit 12 = EXPECT 12 |
| `tests/cases/virtual_dispatch.cpp` | exit 23 = EXPECT 23 |
| `tests/pathb-qbe/traps/*.cpp` (11 programs) | SIGABRT as required: bounds, div_zero, div_overflow, rem_overflow, shift_count, shift_negative, float_to_int, null_deref, no_return, signed_add, signed_mul_wide |

The 17 programs that match `EXPECT` also match the gcc backend. The probes are small and hand-written, so
passing them is evidence, not proof of correctness.

Coverage on `tests/cases` (`tests/pathb-ir/run.sh`): 1997 node occurrences lowered, 0 unsupported, 45
distinct kinds, all lowered. The gap probe `tests/pathb-ir/gaps.cpp` prints 8 unsupported markers, which
the runner checks.

## Closed gaps

- **Variadic calls.** The IR marks a call to a variadic callee with `(variadic N)` (stage 2, section 6) and the
  emitter writes `...` after the N-th argument. Probe: `tests/pathb-qbe/cases/variadic.cpp` (snprintf/sprintf with
  float, double, long and more than eight double arguments, compared in the program; exit code = number of wrong
  results). Before the fix: exit 1, EXPECT 0 (MISMATCH). After: exit 0.

- **Linkage of multi-translation-unit programs.** The IR carries `(weak)` on COMDAT definitions (stage 2, section 6),
  taken from EDG's `use_comdat` (routines) and `comdat_group` (variables). The emitter exports them and writes a
  `# pathb-weak SYMBOL` comment line in the IL. QBE has no weak linkage, so `pathb-qbe-emit.rb --append-weak IL ASM`
  appends `.weak` directives to QBE's assembly (the runner does this after `qbe`). Probe:
  `tests/pathb-qbe/multi/comdat/` (`a.cpp` and `b.cpp` include `common.h` with an inline function, a template, an
  inline function with a static local, an inline variable and a class with inline virtuals). The runner links both
  objects. Before: the link fails with 14 `multiple definition of` errors. After: exit 54 = EXPECT 54, gcc backend 54.
  Not covered: per-function `.section` COMDAT groups (`.weak` is enough on ELF for merging; unused weak copies stay
  in the object), and `static` data that is genuinely different between units (it stays internal).

## Known gaps

- **Pointer subscripts** are not bounds-checked, and the IR has no `undef`, SSA or constant folding.
- **Hexadecimal unsigned constants** are fine for the emitter but not what a consumer might expect.
- **`setjmp`:** the fix keeps every slot of a function that calls `setjmp` in memory, which is stronger than C
  requires (and costs the promotion in that function). Other functions are unchanged. Functions are recognised by
  the callee name, so an indirect call to `setjmp` is not.
- **Reachability** is done by the emitter, not the IR: the IR still prints every routine EDG marks as needed.
  (Routines that run without a reference carry `(constructor)`/`(destructor)` since the dynamic-initialization round
  below, and are roots.)
- **Layout:** only the scalar sizes are checked; alignment of scalars is the one printed on slots and globals.

## Closed gaps (stage 3, second round)

Each has a probe in `tests/pathb-qbe/cases` (translation validation) and a golden in `tests/pathb-ir`.

- **`continue`.** EDG's lowering turns `continue` into a `goto` to an unnamed label that ends the loop body. The IR now
  prints `(continue)` for a goto to the innermost loop's own end-of-body label and drops that label; a goto to an outer
  loop's label (never produced by source `continue`) stays a goto and keeps its label. The emitter jumps to the loop's
  `step` block. Probe: `continue.cpp` (for, while, do-while, nested loops; exit 100 = EXPECT 100, gcc 100). The golden
  `tests/pathb-ir/continue.ir` shows the nodes; `gaps.ir` changed for the same reason.
- **Bool loads.** The emitter normalises every `bool` load to 0 or 1 (`cnew`), so `!`, `==`, conversions to `int` and
  arguments see a canonical value. Probe: `bool_load.cpp` writes 2, 0x80 and 255 into bool objects through
  `unsigned char` and a union. C++ leaves such an object undefined, so the runner skips the gcc comparison for a probe
  with a `// GCC: undefined` line. Before: exit 6, EXPECT 0. After: exit 0.
- **Reachability.** `pathb-qbe-emit.rb` keeps the external definitions and what they refer to (`@"..."` and `&"..."`,
  transitively) and drops unreachable `(static)` and `(weak)` definitions; `--no-prune` turns it off. Declarations
  and string data stay. Probe: `reachability.cpp` has an unused static function, an unused inline function, an
  unused template instance and an unused class with a virtual function, each using `long double` or `volatile`, which the
  emitter refuses. Before: `refused: type long_double`. After: exit 42 = EXPECT 42, gcc 42.
- **`setjmp`.** QBE promotes stack slots to temporaries and forwards stores to loads, and it does not know that
  `setjmp` returns twice. A function that calls `setjmp`, `_setjmp`, `sigsetjmp`, `__sigsetjmp`, `savectx`, `vfork` or
  `getcontext` now stores the address of each of its slots into a module-level sink, so the slots escape and their
  values stay in memory. (A stack slot as the sink does not work: QBE promotes it first, and the stores vanish.) Probe:
  `setjmp.cpp` assigns locals after `setjmp` and reads them after `longjmp`; before: exit 33, EXPECT 77; after: exit 77.
  The gcc backend is not compared (the locals are indeterminate in C).
- **LP64 layout.** The module header now prints `(layout (short N) (int N) (long N) (long_long N) (pointer N) (float N)
  (double N) (long_double N))` from EDG's target sizes, and the emitter refuses a target that is not LP64
  (`refused: layout: ...`). All goldens changed by that header line.

Last run of the second round: `tests/pathb-ir/run.sh` ok (goldens, 45 kinds, 0 unsupported, 8 markers in the gap probe);
`tests/pathb-qbe/run.sh`: 32 programs, 32 built, 32 ran, 21 match EXPECT, 11 trapped as required, 0 refused, 0 failed;
`tests/run.sh` ok.

## Reproduce

```
export S=$(mktemp -d)
PATHB_OUT=$S/pathb scripts/setup-pathb.sh
export PATHB_CPFE=$S/pathb/cmake/bin/cpfe PATHB_BASE=$S/pathb/edg-base
tests/pathb-ir/run.sh          # IR goldens, coverage and the gap probe
tests/pathb-qbe/run.sh         # translation validation
```

`scripts/pathb-dump --ir FILE.cpp | scripts/mrb scripts/pathb-qbe-emit.rb - > x.ssa` shows the emitter output for
one file.

## Dynamic initialization (round 3)

Probes in `tests/pathb-qbe/cases/dyn_*.cpp` and `tests/pathb-qbe/multi/dyn_init/`; they print, and the runner
requires the same standard output as the gcc backend (`// STDOUT: same`).

What EDG's lowering gives (checked on the IL and on the path A C output): with `DO_IL_LOWERING=1` every dynamic
initialization is already explicit. Constructor calls (`dik_constructor`), temporaries and their destructors, `new` /
`delete`, `new[]` with the cookie and `__cxa_vec_*` helpers, local statics with `__cxa_guard_*`, and the
destruction of static objects (`__cxa_atexit`) are ordinary statements and calls in the IR. File-scope dynamic
initializers are collected in one routine per translation unit, `__sti__<file>_<first entity>` (plus one per GNU
`init_priority`), and the C back end marks it `__attribute__((constructor))`. Before this round the IR printed that
routine without a marker and the emitter exported it as an ordinary function that nothing called, so no global
constructor ever ran (and a `static` attribute function would also have been pruned).

Changes:

- **IR:** `(constructor [PRIO])` / `(destructor [PRIO])` on functions (stage 2, section 6, "Start-up and exit"):
  the `__sti__` routines and `__attribute__((constructor/destructor [(N)]))`. Unnamed routines (the array destroyer
  registered with `__cxa_atexit`) get a unique `__unnamed_fn` name at definition and references; before, the
  definition was `"tmp"` (clashing with a static of that name) and the references `"fn"`. Names of routines are
  reserved against static objects. `dik_constructor` initializers lower to a constructor call. A scalar
  `lvalue_adjust` used as an lvalue is supported (`const int c = f();` at file scope).
- **Emitter:** a marked function gets a pointer in `.init_array` / `.fini_array` (`section ".init_array.PPPPP"`
  `"aw"` for a priority, five decimal places as GCC names it), one data object per entry, and is a reachability
  root. The address of a function defined in another unit (for example `operator delete[]` passed to
  `__cxa_vec_delete`) is loaded from a local pointer cell `pathb_got.NAME` instead of a `leaq NAME(%rip)`, which a PIE
  link rejects for a shared-library symbol; direct calls are unchanged.
- **Runner:** `// STDOUT: same`.

Order (matches path A on the probes): priorities ascending, then the routines without a priority in module order
(`dyn_ctor_attr.cpp` mixes `static` attribute functions with a global's `__sti__` routine); destructors from
`__cxa_atexit` run before `.fini_array` entries, as in path A. Across translation units the order is the link order
of the objects, as for gcc.

Still missing: thread-local objects (`thread_local` with a dynamic initializer: the lowering makes `TLS init
function for X` routines; the IR prints them, nothing calls them and the link fails with an undefined reference; that
belongs with the TLS work), and any check of the order of initialization across translation units beyond "all
run before main". The local-static guard is whatever `__cxa_guard_acquire` / `__cxa_guard_release` of the linked C++
runtime does; the probes are single-threaded. The `dik_constructor` lowering is untested because the lowered IL never
contains one.
