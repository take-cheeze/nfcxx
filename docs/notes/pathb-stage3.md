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

- **Pointer subscripts** are not bounds-checked (a pointer has no length), and the IR has no `undef`, SSA or constant
  folding. See "Decisions" in the third round below.
- **Hexadecimal unsigned constants** are fine for the emitter but not what a consumer might expect.
- **`setjmp`:** the fix keeps every slot of a function that calls `setjmp` in memory, which is stronger than C
  requires (and costs the promotion in that function). Other functions are unchanged. Functions are recognised by
  the callee name, so an indirect call to `setjmp` is not.
- **Reachability** is done by the emitter, not the IR: the IR still prints every routine EDG marks as needed.
  Routines whose only job is a side effect without a reference (`__attribute__((constructor))` on a `static` function)
  would be dropped; the IR carries no marker for them.
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

## Third round: volatile, thread-local objects, the indirect-call check

Probes: `tests/pathb-qbe/cases/volatile.cpp`, `tests/pathb-qbe/cases/tls.cpp`, `tests/pathb-qbe/multi/tls_extern/`,
`tests/pathb-qbe/traps/indirect_null*.cpp`; IR goldens `tests/pathb-ir/{volatile,tls}.ir`; emitter edge cases
`tests/mruby/pathb-edge/{volatile_access,thread_data,r_thread_addr,weakref_tls_init}.ir`. The Python oracle
`tests/mruby/oracle/pathb-qbe-emit.py` has the same changes, so `tests/mruby/run.sh` still compares the two byte for byte.

### volatile

IR side (`be/nfcxx_ir.c`): the IR already printed `load.v`/`store.v`, but only for some accesses. EDG drops the
cv-qualifiers from the node type of an rvalue use, so `*p` for `volatile int *p`, a read of a volatile local or
parameter, and a plain read of a volatile member printed a plain `load` (writes and `+=` were fine). The flag now also
comes from the variable's declared type, the base object of a member access (a member of a volatile object), the
declared type of the field, and the pointee/element type of the pointer or array operand (`ir_pointee_is_volatile`).
Type text keeps `(volatile T)` wrappers.

What QBE does to a plain load or store (checked on a hand-written module, `qbe` from `build/qbe`): `load.c` merges two
loads of one address into one (`twice(p)` becomes one `movl (%rdi)` and `addl %eax, %eax`); an unused load is deleted;
a load in a spin loop is hoisted out of it (`while (!*p);` becomes a single load and an infinite loop); a slot that
only loads and stores use is promoted to a register. cproc/`qbe-prep.rb` get away with dropping `volatile` for C input
only for escaped objects, plus the `__nfcxx_keep` call that makes volatile locals escape; that is not enough for
Path B, because an access through a pointer or to a global can still be merged or removed by `load.c` and by the
dead-load elimination.

Lowering (`scripts/pathb-qbe-emit.rb`, `r_load`, `s_store`, `vhelper`): a volatile access is a call of a helper function
that the module defines (non-exported, one per access kind: `__pathb_vld_w`, `__pathb_vst_l`, `__pathb_vld_sb`, ...,
each with one real QBE `load`/`store`):

```
%t =w call $__pathb_vld_w(l %addr)            # (load.v int ADDR)
call $__pathb_vst_h(l %addr, w %val)          # (store.v unsigned_short ADDR VAL)
```

QBE has no inliner, never merges, moves or deletes a call, and keeps calls in program order, so every volatile access
is executed exactly once and in order with respect to the others and to every call. The address operand of the call
makes a stack slot escape, so volatile locals, volatile parameters and volatile arrays stay in memory (the
mem2reg-style promotion only fires when loads and stores are the sole uses). The same holds for volatile globals and
for accesses through pointers to volatile objects: nothing is special-cased by storage class. Bool loads are still
normalised after the helper call; narrow loads use the sign/zero-extending load in the helper.

Checked: the probe runs a loop `while (!g_flag) {}` that a second pthread ends (it hangs if the load is hoisted),
volatile sums, volatile struct members, a volatile parameter, `volatile` arrays, pointer-to-volatile parameters,
`int *volatile`, `const volatile`, a volatile bool, long, double, unsigned char (exit 0 = EXPECT 0, gcc 0).
`tests/pathb-qbe/run.sh` also checks the assembly: `// ASM-COUNT: FUNCTION PREFIX N` lines require N calls
with that callee prefix in the QBE output of FUNCTION (`vol_twice` has two loads, `vol_unused_read` one, `vol_two_stores`
two stores, `vol_local` four accesses, and the control `plain_twice` has none, so the check tells the two apart).

Limits:

- One call per access, so volatile code is slow (a `movl` becomes a call and a return). Correctness first; an
  inline sequence would need QBE support (an instruction that is not eliminated), which it does not have.
- Volatile is not atomic and not a fence. The helper does one naturally aligned `mov` for sizes up to 8 bytes (x86-64,
  as C++ gives no more); the call is a compiler barrier for escaped memory only.
- A copy of a whole volatile aggregate (`(copy N DST SRC)`) is not marked; it is a `memmove` call, which is not
  elided, but not a per-member volatile access either (C++ leaves this unspecified).
- Volatile bit-fields and `long double` are still refused (bit-fields are unsupported in the IR anyway).
- The helpers are emitted per translation unit, only when used, and are not exported, so linking several units is fine.

### Thread-local objects

IR: `(global NAME TYPE BYTES ALIGN [(static)|(weak)] [(thread)] INIT)`. `(thread)` is printed for `thread_local`
(EDG `is_thread_local`) and for the GNU `__thread` (only `decl_modifiers & DM_THREAD`; the first version missed these),
for definitions and `extern` declarations alike, and for function-local `static thread_local` objects. The INIT is the
initial image of the thread's copy.

QBE (checked against `3rd/qbe/amd64`): `thread export data $x = align 4 { w 5 }` goes to `.tdata` (`.tbss` when it is
all `z`); a reference is an operand with the `thread` prefix. A definition in the module is referenced as `thread $x`
(local-exec: `movl %fs:x@tpoff, %eax`, `leaq x@tpoff(%rax)`), a declaration as `extern thread $x` (initial-exec through
`x@gottpoff(%rip)`), so the object can be defined in another object file. The emitter writes the address of a
thread-local object to a temporary, `%t =l copy thread $x`, wherever the IR uses `@"x"`, so the address is a plain
`l` value (compares, calls, `memmove`) and the access forms are unchanged. Local-exec needs the object file to end up
in an executable; a shared library would have to use `extern thread` for definitions as well (one line in `opnd_`).

The C++11 wrapper functions for `extern thread_local` variables (`_ZTW<name>` calls `_ZTH<name>` if it is not null)
refer to a weak undefined function. The IR has no weak declarations, so the emitter treats an undefined function whose
name starts with `_ZTH` as a weak reference: it is referenced through the GOT (`extern $_ZTH...`) and marked
`# pathb-weak` (`.weak` through `--append-weak`). Dynamic initialization of thread-locals (`thread_local std::string`)
is not lowered (stage 3 `(unsupported init dynamic)`), so no `_ZTH` function is ever defined by this Path B yet.

Checked: `tls.cpp` has `__thread`, `thread_local`, zero, initialized, array, struct, a `static` (internal) and a
function-local one; the main thread writes its copies, a pthread must see the initializers, change its copies, and main
must see its own values untouched (exit 0, gcc 0). `multi/tls_extern`: one unit defines, the other declares
(`extern thread_local int`, `extern __thread double[3]`) and a second thread sees its own copies (exit 0, gcc 0).
Before the `__thread` fix the probe returned 17 (the `__thread` objects were shared).

Limits: the address of a thread-local object in a static initializer is refused (it is not a constant);
x86-64 ELF only (QBE's other targets have their own TLS sequences, and `apple`/Windows are not supported).

### Indirect-call null check (stage 2, gap 9)

`ir_call` prints `(nonnull F)` before a call through a function pointer, unless the callee operand is an address.
Virtual calls and calls through a pointer member go through it. Probes: `traps/indirect_null.cpp` and
`traps/indirect_null_member.cpp` (both call through a good pointer first, then through nullptr; both abort with
SIGABRT; without the check the call faults with SIGSEGV instead). Goldens that gained a `(nonnull ...)` line:
`virtual_dispatch.ir`, `reachability.ir`.

### Decisions: `undef` and pointer subscript bounds

- **`undef`: not implemented.** A read of an uninitialized object is undefined behavior in C++ (apart from copying
  `unsigned char`), so nothing has to be preserved, and the QBE slot just holds whatever is in memory (or, once QBE
  promotes the slot to a temporary, an undefined temporary that it reads as 0). An IR `undef` would have to be printed
  at the read, which needs a definite-assignment analysis over the lowered statements (loops, `goto`, `switch` fallthrough,
  address-taken slots, partially initialized aggregates). A cheap version, "no store to the slot before this load in
  source order", is unsound for loops (the store comes later in the text but earlier in time) and wrong for slots that are
  initialized through a pointer. A sound version is not cheap, and the only consumer (QBE) would ignore it. If a
  consumer needs it (a GPU back end, a checker), the right place is an IR pass over `(slot ...)` and the statements,
  not the lowering.
- **Pointer subscripts: not bounds-checked, by design.** `p[i]` has no length to check against. An array subscript
  `a[i]` and `array_to_pointer(a)[i]` are checked (`(bounds IDX N)`). Checking pointer subscripts needs fat pointers
  (an ABI change) or a shadow allocation map (a sanitizer), neither of which belongs to the lowering. Null checks on
  dereference stay as before.

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
