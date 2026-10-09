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

- volatile loads and stores (and volatile bit-field accesses, `bfload.v`/`bfstore.v`);
- `long double`;
- a variable-length array *slot* (VLAs themselves are fine since round 3: the IR uses a pointer slot) and the other
  unsupported IR markers (inline asm, constructor initializers);
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
distinct kinds, all lowered. The gap probe `tests/pathb-ir/gaps.cpp` printed 8 unsupported markers in rounds 1-2
(1 since round 3: inline asm), which the runner checks.

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
  the callee name, so an indirect call to `setjmp` is not. It is also what C++ exceptions rely on (section "C++ exceptions" below).
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

## Closed gaps (stage 3, third round): bit-fields, variable-length arrays, statement expressions

IR grammar and semantics: `docs/notes/pathb-stage2.md`, sections 5a-5c. Probes in `tests/pathb-qbe/cases` (all compared
with the gcc backend, exit code = number of wrong results, EXPECT 0), goldens in `tests/pathb-ir`:

- **Bit-fields** (`bitfield.cpp`, `bitfield2.cpp`): reads and writes of signed and unsigned fields (1 to 64 bits, `bool`,
  enum, `char`/`short`/`long long` declared types), truncation and sign extension, neighbours untouched, compound
  assignment and `++`/`--` with the value used, struct copies, static and local aggregate initializers, a packed struct,
  base and derived classes, a class with a vptr, a union, a reference bound to a bit-field, a switch on a bit-field.
  Before: `(unsupported lvalue points_to_field)` and the emitter refused the module. After: exit 0 = EXPECT 0, gcc 0.
- **Variable-length arrays** (`vla.cpp`): `sizeof` of a VLA and of a row, two dimensions, a pointer to a VLA row
  (`int (*p)[m]`, stride computed at run time), a loop allocating 4-8 KB 200000 times (it would overflow the stack if
  every iteration kept its space), a growing size, recursion, a backward `goto`, a VLA of structs, a VLA in a `switch`.
- **Statement expressions** (`stmtexpr.cpp`): value of the last expression, nesting, locals, use in a loop condition,
  `break`/`continue`/`return`/`goto` leaving one, a struct result, a VLA inside, evaluation order.

Emitter changes: `bfload`/`bfstore` (read-modify-write of the unit), `vlaalloc` (QBE `alloc16` outside `@start` with a
per-statement capacity, see `s_vlaalloc`), a register `SIZE` for `index` and `pdiff`, `(bitfield ...)` initializer items.
`tests/mruby/oracle/pathb-qbe-emit.py` has the same changes, and `tests/mruby/pathb-edge/{bitfield,vla}.ir` plus the
`e_bf*`/`r_bf*` files cover their edge and error paths in the py-vs-rb comparison (mruby's bigint complements negative
numbers wrongly, so the emitter computes masks with `^` on positive values instead of `~`).

**A QBE bug found on the way.** With the first version of `r_bfload` (a shift and an `and` with a low mask) the probe
passed, but a program with the `do { if (!(c)) ++bad; } while (0)` macro around bit-field reads gave a wrong result:
QBE's "redundant and mask" (`3rd/qbe/copy.c`, `defwidthle`/`dwl`) removed `and x, 15` from a value that had bits
above bit 3. The width analysis marks a phi as visited (`p->visit`) and does not undo it when a path fails, so a
second query on the same phi in one traversal answers "narrow". The workaround is in the emitter: extraction and
insertion use shift pairs, and the "keep the other bits" mask is applied with `and` only when it is not of the form
2^k-1 (the field at the top of the unit uses a shift pair instead). `bitfield2.cpp` uses that macro on purpose. The
same QBE bug can in principle bite any `and x, 2^k-1` that the emitter produces for other reasons; none is known.

**Still missing**

- VLA storage is not freed at block exit (the IL has no scope marker); it is reused when the same declaration executes
  again, so loops and recursion are bounded, but a function that declares different VLAs in sequence in one scope
  keeps all of them until it returns. A VLA subscript has no bounds check.
- Volatile bit-fields are lowered (`bfload.v`) but the QBE emitter refuses them, like every volatile access.
- Bit-fields in a union or in a class with a virtual base have no aggregate initializer path (the IR has none for those
  classes); plain access works.
- A statement expression that returns a class by copy constructor stays `(unsupported stmt stmt_expr_result)`;
  inline asm is still unsupported (the one marker left in `gaps.cpp`).

## C++ exceptions (stage 3, third round)

Result: try, catch, throw, rethrow, cleanups during unwinding, exception specifications and `noexcept` work in Path B.
Two small lowering fixes were needed; the emitter needed none (the stage 3 `setjmp` treatment already covers EDG's EH ABI).
Probes: `tests/pathb-qbe/cases/eh_*.cpp` (9 programs, checked against EXPECT 0 and the gcc backend) and
`tests/pathb-qbe/traps/eh_*.cpp` (3 programs that must call `std::terminate`); golden `tests/pathb-ir/eh_thunk.ir`.

### What the lowered IL looks like

EDG lowers exceptions to C-level code plus calls into its EH runtime (`3rd/edg/lib_src/throw.c`, `eh.h`; the ABI is
described in `docs/notes/hexagon.md`, section 3a). Path A prints the same thing as C (`nfcxx --emit-c`). The IL has no
try/catch/throw node after lowering. What the IR sees is ordinary statements and calls:

| Source | Lowered IL (and so the IR) |
| --- | --- |
| function with something to unwind (a local with a destructor, a try, a `noexcept` or `throw(...)` function) | a local `__C7` EH stack entry (240 bytes: `next`, `kind`, and a union that holds the try block's `long setjmp_buffer[25]`, the catch table and the region number), pushed on `__curr_eh_stack_entry` in the prologue and popped on every exit. `kind` is 1 = function (with a static region table `{dtor, handle, next, flags}`), 2 = throw specification, 4 = vec new/delete, 5 = try block, 6 = noexcept. `__eh_curr_region` (an `unsigned short`) says which locals are alive and is assigned as objects are constructed and destroyed |
| `try { B } catch ...` | a kind-5 entry, then `if (_setjmp(entry.variant.try_block.setjmp_buffer) == 0) { B } else if (__catch_clause_number == 1) { e = (T*)__caught_object_address; ...; __exception_caught(); H; __destroy_exception_object(); }`. The static catch table `{typeinfo, flags, ptr_flags}` is a function-local static array (an IR `(global ... (static))`) |
| `throw X` | `p = __throw_setup(&typeinfo, sizeof(X), flags)` (or `__throw_setup_dtor` / `__throw_setup_ptr`), construct X into `p`, `__throw()` |
| `throw;` | `__rethrow()` |
| function-try-block | the same as a try block around the body (a constructor's handler rethrows implicitly) |
| `throw(int)`, `noexcept` | kind-2 and kind-6 entries; a violation reaches `__call_unexpected` / `__call_terminate` in the runtime |
| destructors during unwinding | not generated code: `__throw` walks the EH stack (pass 1 finds the handler by type, pass 2 runs each function entry's region chain, which calls the destructors through the static region table) and `longjmp`s into the try |
| typeinfo | ordinary weak globals `_ZTI...` / `_ZTS...` (`__class_type_info`, `__si_class_type_info`, `__vmi_class_type_info`, `__function_type_info`) initialised with `(addr ...)` items |

Every node kind involved already existed in the IR: `tests/pathb-ir/exceptions.ir` has had no unsupported node since stage 2.
The programs written for this round found two gaps, both outside the EH code itself and now closed:

1. `enk_result_of_overriding_function` printed `(unsupported node result_of_overriding_function)`. It is the body of an IA-64
   this-adjusting thunk such as `_ZThn16_N2PQD0Ev`, the destructor of a second base class, which every class with two polymorphic
   bases has (thrown, deleted through a base pointer, or merely given a vtable). EDG's C generator expands the node to a call of
   `curr_routine->overriding_function_for_wrapper` with the thunk's own parameters. `ir_roof` in `be/nfcxx_ir.c` does the same: the
   thunk has adjusted `this` in its slot already, so the current value of each parameter slot is passed (an aggregate parameter is
   copied, an aggregate result goes through a temporary). A thunk of a variadic function keeps the marker (EDG expands those in the
   master routine). Covariant-return wrappers (`_ZTch...`) are expanded by EDG itself and did not need it.
   Before: the emitter refused the module (`refused: statement (unsupported ...)`). After: `eh_thunk.cpp` and `eh_cast.cpp` run.
2. `throw &f` (the address of a function in a non-constant expression) printed `(unsupported lvalue)`: `ir_lval` had no case for
   `enk_routine`. It is now the function's address, `&"f"`. Before: the module was refused. After: `eh_types.cpp` and
   `eh_cast.cpp` run.

### How a Path B program gets the EH runtime

The generated code calls `__throw_setup`, `__throw`, `__rethrow`, `__exception_caught`, `__destroy_exception_object`,
`__cxa_vec_*` and refers to the typeinfo vtables by name. They are in EDG's `libC.a`, which `scripts/setup-edg.sh` builds from
`3rd/edg/lib_src/*.c` (`throw.c` among them) and which path A links through `eccp`. Path B links the same archive:
`tests/pathb-qbe/run.sh` passes `-L build/edg/lib -lC -lstdc++ -lgcc_s -lpthread`. Nothing is compiled by cproc or gcc for the test: the
runtime is the same binary as in path A, so the two paths agree on the ABI by construction (the `long[25]` jmp_buf size in the
generated entry type comes from glibc's `jmp_buf`, the same one `_setjmp` is called with).
One change in the harness was necessary: `-lC` now comes before `-lstdc++`. Before, libstdc++.so provided `operator new[]` and
`operator delete[]` first, and a program that takes the address of one (the vec-new/delete cleanup table of an array `new`) failed
to link as a PIE (`relocation R_X86_64_PC32 against symbol _ZdaPvm`). With libC.a first the program uses EDG's own operator
new/delete and exception runtime.

A Path B build for another target would compile `lib_src/*.c` with the target's C compiler (`tests/hexagon/eh_rt.c` is a hand-trimmed
port of `throw.c` for Hexagon, which has no libc here) and fix `TARG_JMP_BUF_NUM_ELEMENTS` to the target `jmp_buf`.

### Why `setjmp` needs the memory treatment, and why `volatile` does not

The stage 3 second round keeps every slot of a function that calls `_setjmp` in memory (`escape_slots`). That is the whole answer
for EH: EDG's try block is `if (_setjmp(buf) == 0) { body } else { handler }`, and the handler reads locals that the body assigned
before the throw. Without the treatment QBE promotes those slots to temporaries and the handler sees the values from the `setjmp`
call. Evidence: with `escape_slots` disabled, `eh_basic.cpp` returns 2 (two wrong results); with it, 0.
The lowered IL contains no `volatile` (no `load.v` or `store.v` in any EH probe): EDG relies on the C compiler's `setjmp` rules instead of
marking locals volatile. SSA temporaries that live across the `setjmp` call are defined before it and never change, so the callee-saved
registers that `longjmp` restores hold the right values. `_setjmp` is in `RETURNS_TWICE` already. A `volatile` local that the program
itself declares is a different matter (the volatile work).

### Verified behaviour (all equal to the gcc backend)

- `eh_basic`: throw/catch of `int`, `long`, `char`, `double`, pointers, `const char *`, a class by value and by `const&`, a derived
  class caught by base reference and by base value (slicing), handler order, `catch (...)`, no-match fallthrough to an outer try,
  rethrow of scalars and of a derived object, throwing from a handler, nested try inside try and inside a handler, a throw across
  four frames, try in a loop with `break`, `continue` and `return` in the try body.
- `eh_unwind`: destructor order (digit traces) for one frame and several frames, nested scopes, arrays of objects, a throwing
  constructor (member destroyed, own destructor not run), a throwing member initializer, temporaries, the copy made by `throw lvalue`,
  a rethrow through a handler with its own local, a loop of try blocks, `return` from a try inside a function with a guard.
- `eh_special`: function-try-block of a function and of a constructor (rethrow after the members are destroyed), `noexcept`, a derived
  pointer caught as base pointer / `const int *` / `void *`, a throw through a virtual call and a function pointer, a class template
  thrown, an exception thrown while another is being handled, recursion with handlers at several levels.
- `eh_more`: multiple and virtual inheritance catch matching (the runtime adjusts the pointer), `new` with a throwing constructor
  (memory freed), `new T[n]` with a throwing element (`__cxa_vec_new3`, built elements destroyed), a function-local static whose
  initializer throws (guard reset), `goto`/`switch`/`break` in the try body, slicing.
- `eh_spec` (`// STD: c++14`): dynamic exception specifications with several types and with a base class, `throw()`, `noexcept`,
  `noexcept(false)`, a template with a specification. The violations are `traps/eh_uncaught`, `eh_noexcept` and `eh_unexpected`
  (c++14): the runtime prints `C++ runtime abort: terminate() called by the exception handling mechanism` and aborts. The runner
  requires both the SIGABRT and the message (`// TRAP-STDERR:`), so a program that aborts for another reason does not pass.
- `eh_types`: which handler a thrown type selects, for every fundamental integer and float type (no conversion between them), an enum and
  an `enum class`, `const char *`, `void *`, a function pointer, pointer to pointer, `nullptr`, a class with an array member, lambdas
  that throw or catch, templates.
- `eh_cast`: `dynamic_cast` to a reference that fails throws `std::bad_cast` from the runtime (caught with `catch (...)`), covariant
  returns with a second base, `throw &f`. `eh_thunk` repeats the thunk and `throw &f` in a small probe that has a golden.

Last run of the third round: `tests/pathb-qbe/run.sh`: 44 programs, 44 built, 44 ran, 30 match EXPECT (and the gcc backend), 14 trapped
as required, 0 refused, 0 failed; `tests/pathb-ir/run.sh` ok (goldens, 45 kinds, 0 unsupported, 8 markers in the gap probe);
`tests/mruby/run.sh` ok for the emitter (the emitter is unchanged; 382 runs identical, the new IR included); `tests/run.sh` ok.

### Limits

- **Headers.** The Path B harness gives EDG only `include_c++` (`--sys_include=$PATHB_BASE/include`), which has no C library headers.
  `<exception>` and `<typeinfo>` work (`eh_std.cpp`: a class derived from `std::exception` caught as `std::exception &`, `std::bad_typeid`,
  `std::bad_cast` caught by its own type and by `std::exception &`, `typeid` equality). `<new>` fails with
  `cannot open source file "stddef.h"`, so `std::bad_alloc` and `std::nothrow` are not testable here, and EDG's `<stdexcept>` does not
  declare `std::runtime_error`. This is the harness, not the IR. `__builtin_printf` is not mapped to `printf` either (link error),
  so the probes report through the exit code.
- **`long double`** is refused by the emitter as before: a handler or a throw of `long double` refuses the module. A
  `volatile`-qualified handler type refuses it until the volatile work lands (the probe uses `const int *`).
- **Union aggregate constants** (a local `{{1,2,3,4}, {7}}` with a union member) and **default member initializers on a class with a
  base and a vptr** give `(unsupported init aggregate-constant)` (`ir_init_constant`). They showed up while writing EH probes but are
  not related to exceptions; the probes avoid them.
- **Exceptions in dynamic initialization** (a throwing initializer of a namespace-scope object) depend on the dynamic initialization
  work.
- **Cost.** Every function with an EH stack entry has a 240-byte slot and, since it calls `_setjmp`, all its slots in memory. A try
  block in a hot loop pays for that; this ABI has no zero-cost (table-driven) unwinding.
- The `lowered_eh` expression nodes (`leck_*`, `DO_FULL_PORTABLE_EH_LOWERING` off) are not what this EDG build produces and are not
  handled; no probe contains one.

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
