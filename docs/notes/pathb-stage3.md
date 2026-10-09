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
- **The emitter** (`scripts/pathb-qbe-emit.py`) reads the IR text and writes QBE IL.

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
Trap programs must abort with `SIGABRT`; gcc is not compared for them, because C leaves those cases undefined.

Last run (on `main` at the time of writing):

```
26 programs: 26 built, 26 ran, 15 match EXPECT, 11 trapped as required, 0 refused, 0 failed
```

| Program | Result |
| --- | --- |
| `tests/pathb-qbe/cases/arith.cpp` | exit 14 = EXPECT 14 |
| `tests/pathb-qbe/cases/calls.cpp` | exit 94 = EXPECT 94 |
| `tests/pathb-qbe/cases/control.cpp` | exit 237 = EXPECT 237 |
| `tests/pathb-qbe/cases/floats.cpp` | exit 13 = EXPECT 13 |
| `tests/pathb-qbe/cases/globals.cpp` | exit 21 = EXPECT 21 |
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

The 15 programs that match `EXPECT` also match the gcc backend. The probes are small and hand-written, so
passing them is evidence, not proof of correctness.

Coverage on `tests/cases` (`tests/pathb-ir/run.sh`): 1997 node occurrences lowered, 0 unsupported, 45
distinct kinds, all lowered. The gap probe `tests/pathb-ir/gaps.cpp` prints 8 unsupported markers, which
the runner checks.

## Known gaps

- **Variadic calls.** The IR does not mark a callee as variadic, so no `...` is emitted at call sites.
  Calls with float arguments to printf-like functions are unsafe.
- **`setjmp`.** QBE does not know that `setjmp` returns twice. Slots are promoted, so values changed after
  `setjmp` may be stale after `longjmp`. `exceptions` passes, but that is not proof.
- **Reachability.** Every routine EDG marks as needed is still printed.
- **`continue`** is still a `goto`. There is no structurizer.
- **Bool loads** are not normalised: a `bool` holding a value other than 0 or 1 is undefined here.
- **Pointer subscripts** are not bounds-checked, and the IR has no `undef`, SSA or constant folding.
- **Layout** assumes LP64 scalar sizes (int 4, long 8, pointers 8). The IR prints no scalar sizes.
- **Linkage.** Defined globals and functions are exported unless marked static. COMDAT and weak symbols are
  not modelled, so the output is only safe for single-translation-unit programs.
- **Hexadecimal unsigned constants** are fine for the emitter but not what a consumer might expect.

## Reproduce

```
export S=$(mktemp -d)
PATHB_OUT=$S/pathb scripts/setup-pathb.sh
export PATHB_CPFE=$S/pathb/cmake/bin/cpfe PATHB_BASE=$S/pathb/edg-base
tests/pathb-ir/run.sh          # IR goldens, coverage and the gap probe
tests/pathb-qbe/run.sh         # translation validation
```

`scripts/pathb-dump --ir FILE.cpp | python3 scripts/pathb-qbe-emit.py - > x.ssa` shows the emitter output for
one file.
