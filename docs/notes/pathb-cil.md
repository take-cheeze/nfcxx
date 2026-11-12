# Path B to CIL: C++ exceptions as CLR exceptions (spike), and the C route of the CIL backend

`scripts/pathb-cil file.cpp -o x` compiles a C++ file through Path B's IR and runs it as a .NET 8 assembly. It is the
spike of the route chosen for C++ exceptions on CIL (see `docs/notes/cil.md`, "Not supported"): the exception handling
of Path B's IR is turned into CLR `try`/`catch`, not into EDG's `setjmp`/`longjmp` runtime.

## Pipeline

```
C++ --pathb-dump --ir--> Path B IR --pathb-cil-emit.rb--> JSON fragment --cil-link.rb--> CIL --ilasm--> x.dll (+ launcher)
```

- `scripts/pathb-cil-emit.rb` (run by `scripts/mrb`) reads the IR text (its format: `docs/notes/pathb-stage2.md`) and writes a fragment, the
  same format `qbe2cil.rb` writes, so `cil-link.rb` links both: one class `Prog`, globals as `addr_<name>` fields,
  `Init` for data, and the entry point.
- The memory model is the C backend's: pointers are int64 addresses, frame slots are one `localloc` per call, and
  globals with initializers are data in `Init`.

## What the IR gives us

EDG lowers `try`/`throw` before Path B sees the code (`3rd/edg/src/lower_eh.c`), so the IR has no `try` node. The
lowered form of `try { B } catch (T) { H }` is, in IR text:

```
(let %20 int (call int &"_setjmp" ...))         ; the eh-stack entry's jmp_buf
(let %21 bool (eq int %20 (const int 0)))
(if %21 (then B) (else (let %35 int (load int @"__catch_clause_number")) ... H))
```

and `throw X` is `__throw_setup(&typeinfo, size, flags)` (storage for X), a store of X, then `__throw()`, which
longjmps in EDG's runtime.

## The translation

- The emitter recognises the `if` whose condition is `_setjmp(...) == 0` and emits `.try { B } catch class CxxThrow { H }`.
- `_setjmp` is 0 (it is only ever the entry test). `__throw_setup` allocates the storage and records its pointer in
  `cxx_ptr`. `__throw` raises `CxxThrow`. The catch copies `cxx_ptr` into `__caught_object_address` and sets
  `__catch_clause_number` to 1, then runs H.
- Inside a `try`, `return`, `break`, `continue` and `goto` leave the region with `leave` (a `return` stores its value
  first); outside, they branch.
- The EH globals (`__curr_eh_stack_entry`, `__eh_curr_region`, `__catch_clause_number`, `__caught_object_address`) are
  zero storage in the program, not dlsym'd (they are the runtime's, and dlsym would give null).

## Results

`tests/pathb-cil/run.sh` (SKIP without dotnet, setup-cil and setup-pathb):

| case | what it shows | result |
|---|---|---|
| `throw_int` | `throw 5` caught in the same function | 5 |
| `throw_across_frames` | the throw is in a callee, caught in the caller | 41 |
| `no_throw` | a `try` that returns normally | 5 |
| `loop_break_in_catch` | `break` out of a handler inside a loop | 150 |
| `two_catches` | several catch clauses: refused, with a message | refused |
| `rem_shift` | `crem` (with a negative dividend), `cshl` and `cshr` with variable counts | 5 |
| `float_ptr` | `fneg`, a volatile load (`load.v`), `pdiff`, a compiler barrier | 12 |
| `small_wrap` | `++` and `--` on `unsigned char`, `signed char` and `short` wrap to the type, in the value of the expression | 42 |
| `shift_abort` | a checked shift with count 40 on an int: aborts | 134 (SIGABRT) |
| `builtin_trap` | the `trap` statement (`__builtin_trap`): aborts | 134 (SIGABRT) |
| `vararg_def` | a C-style variadic definition (va_start): refused, with a message | refused |
| `funcaddr_arg` | `&"f"` passed to a callee, which calls it (calli) | 42 |
| `funcaddr_table` | a static table of function addresses, indexed calls, pointer comparison | 78 |
| `funcaddr_void` | a void callee and a callee given a pointer argument, both called through pointers | 7 |

Coverage of the existing Path B IR corpus (`tests/pathb-ir/*.ir`, 62 files): **24 translate**, 38 are refused. The
refusals, by count:

- 11 variadic calls (`printf`); 3 variadic definitions (`va_start`)
- 8 aggregate values (`struct` or `byval`) used as a value; 3 `std::float16_t`
- 2 `switch`; 2 `fence`; 2 `copy`; 2 `bitfield` initializers
- 1 each: `bfload.v`, `alloca`, `cf2i`, `store.v`, and an asm statement

Checked forms follow the QBE emitter (`scripts/pathb-qbe-emit.rb`, `r_divrem`, `r_shift`): a zero divisor and
`INT_MIN / -1` abort (`crem` and `cdiv`), and a count not in `[0, width)` aborts (`cshl`, `cshr`). `bounds` aborts when
the index is not below the bound, as QBE's abort does. The abort is a call of `abort`, which the linker binds to libc
(SIGABRT, status 134). `trap` takes the same path. `pdiff` is `(A - B) / SIZE`, `fneg` is `neg`, `load.v` is
`volatile.`-prefixed `ldind`, and `barrier` emits nothing.

A register `SIZE` of zero in `pdiff` (a zero-length VLA element) aborts, as the divisor check of `cdiv` does. QBE's
`r_pdiff` has no such check: it emits a plain `div`, which traps (SIGFPE) on x86, so the two differ there. A literal
zero `SIZE` is refused. The frontend does not produce a register `SIZE` for C++ source in this configuration (its VLA
strides are literal sizes with a count), so the zero case is checked with a hand-written IR program, not a `tests/` case;
`tests/pathb-cil/run.sh` checks exit status only, and a CLR unhandled exception also exits 134.

Wrapping arithmetic on a 1- or 2-byte type narrows its result, as the QBE emitter's `narrow` does: `wadd`, `wsub`,
`wmul`, `wneg`, `and`, `or`, `xor` and `cshl` convert the int32 result with `conv.i1`/`conv.u1`/`conv.i2`/`conv.u2`.
`bool` is not narrowed, as in QBE.

The `index` form is `BASE + ext(IDX) * SIZE`, with the extension following the IR type of the index (zero for an
unsigned 32-bit index, sign otherwise). Untyped index operands default to sign extension, as `pathb-stage2.md`
describes; QBE's behaviour for them is not verified.

Two notes on the trap statement. `docs/notes/pathb-stage2.md` says `(trap)` is an illegal instruction (`ud2`, SIGILL),
and the QBE emitter spells it `hlt`. The Path B QBE tests expect that: `tests/pathb-qbe/traps/builtin_trap.cpp` must die
of SIGILL (exit 132), as `docs/notes/builtins.md` records. This emitter follows the abort path instead (SIGABRT, exit 134,
`tests/pathb-cil/cases/builtin_trap.cpp`), so the exit status of a trap differs from QBE's: SIGILL there, SIGABRT here.
Both end the process without returning. The CIL route keeps SIGABRT: it is the clearer exit, and it is what the
libc `abort` path already gives every other checked failure here.

Unknown statements, and any unknown form at the top of a function, are refused. The emitter used to keep only a fixed
list of statement heads at the top of a function and silently drop the rest (`asm_refuse.ir` translated without its
`fence`); that is fixed, and it is why some files that translated before now refuse.

## C inputs, and the route of `cil-cc` (cproc removal, workstream E)

`scripts/pathb-cil` takes C as `./nfcxx` does: a `.c` file is read by EDG's C front end (`pathb-dump --ir -std=c11`, plus
`-D_DEFAULT_SOURCE`, because gcc's default dialect defines it and a strict `-std=c11` leaves `strdup` undeclared, so an implicit `int`
truncates its pointer), several files are several fragments of one link, and `-c` writes one fragment (the object of
`scripts/cil-cc`). A static function, global or string literal is `name@UNIT`, as in `qbe2cil.rb`, so two files may each have a
`static` of one name.

`scripts/cil-cc` (nfcc's `NFCXX_BACKEND=cil`) compiles a `-c file.c` through this route first and falls back to the cproc route
(`qbe-cc`: cproc -> QBE IL -> `qbe2cil.rb`) when Path B refuses the file or the options are not ones it takes (anything beyond
`-c -o -I -D -U -std=` and the ignorable `-O -g -W -fPIC`...). The fragments of both routes link together, so the choice is per file.
`NFCXX_CIL_CPROC=1` takes the cproc route for every file; `NFCXX_CIL_VERBOSE=1` says which route each file took.

What the emitter learned for C: variadic calls (the `nfcxx_vcall` shim of `cil-link.rb`, as `qbe2cil.rb`), `iconv`/`p2i`/`i2p` with the
operand's signedness, `i2f`/`u2f`/`fconv`/`cf2i` (checked), `fadd fsub fmul fdiv`, `lt.f`/`le.f`, `not`, `switch` (a compare chain; `case`
labels must be statements of the body), `alloca`, bit-fields (`bfload`/`bfstore`), `copy`/`zero-fill` (`cpblk`/`initblk`), aggregates
by value (`sret` and `byval` are pointers: the caller makes the copy), `store.v`, and method names that are IL keywords (`add`) quoted.

**Nothing is dropped.** Things the IR carries that this route does not model are refused, so the fallback takes them (before, they
were ignored and the program ran wrong): a top-level form other than module, `abi-type`, `x87-thunk`, `global`, `data`, `function`,
`declare` (an `alias` is one); a weak attribute (a function or global), a weak declaration, `section` and `thread` globals;
`constructor`/`destructor` functions; an object or frame slot aligned to more than 16; a call of an `__nfcxx_*` helper (long double,
`__int128`, `__float128` need `be/nfcxx_ldrt.c`); a `setjmp` that is not the entry test of a lowered `try` (the emitter's `_setjmp` is 0).
Five files of `tests/pathb-ir` that "translated" before (`alias_attr`, `alias_static`, `alias_weakref_ifunc`, `tls`, `weak_decl`) are
therefore refused now, and 53 of the 84 translate (41 before).

### Measured: the programs of `tests/cil`

Every program built and run through Path B (`scripts/pathb-cil`, and through `nfcc` with the routing above), against the exit status and
the stdout the test expects:

| program | Path B | what it needed |
|---|---|---|
| cases/arith, fib, fnptr, hello, loop, misc, strings, structs, switch | run, exit and stdout as expected | variadic calls, conversions, `cf2i`, `switch`, aggregates by value, bit-fields, `alloca`, quoting of `add` |
| cases/conv, nan, f2i64 (new) | run | `conv`: widening, narrowing, float compares, `switch` with `continue`, volatile store, bit-fields, struct by value; `nan` and `f2i64`: see below |
| multi/statics | run | `name@UNIT` for statics |
| errors/variadic_def | refused by Path B (`variadic definitions (va_start) are not supported by the CIL backend`); `cil-cc` does not fall back to cproc for this refusal, which the cproc route makes too | no marker: the error comes from Path B |

So no `tests/cil` program needs cproc to run. `tests/cil/run.sh` fails when a file without a `// QBE-ONLY: reason` marker is taken by
cproc, and when a marked file is not. `cases/nan.c` and `cases/f2i64.c` are `// PATHB-ONLY`: `qbe2cil.rb` gets `nan < 1.0` wrong (true) and converts a double to a 64-bit integer through 32 bits; Path B follows C. (Those two bugs of the cproc route are not fixed here.)

### Measured beyond `tests/cil`: the 63 single-file programs of `tests/c` (only measured, not routed by a test)

36 build and give the expected exit status, and none runs wrong. 27 are refused: 10 `asm` blocks; 4 calls of `__nfcxx_*` runtime helpers
(long double, `__int128`, `__float128`); 4 constructs the front end could not lower (`unsupported`); 2 `_Float16`; 2 over-aligned objects;
and one each: a defined variadic function, a `setjmp`, a `section` global, a weak declaration, and a crash of the initializer reader on
`gnu_fam_init` (a flexible array member's initializer; it exits non-zero, so the fallback takes it). The first measurement, before the
refusals above, found 8 programs that built and ran wrong (the alias, section, alignment and runtime-helper ones, and `setjmp`);
the cproc route did not compile those at all, so routing without the refusals would have turned a compile error into a wrong result.
A file Path B refuses falls back to cproc.

## Limits of this spike (each a refusal or a known wrong result)

- **One catch clause only.** The catch assumes clause 1. Selecting among clauses (and checking the thrown type) needs
  typeinfo objects: EDG's `_ZTI*` are extern here (libc++/libstdc++ define them on hosted builds), so the emitter cannot
  compare them. A try with several clauses is refused. A single catch of a different type than the one thrown is not
  detected: it is a wrong result, so it must be fixed before this route is used on real programs.
- **No destructors during unwinding.** EDG's cleanup tables are not translated. Objects with destructors in the `try`
  block are not destroyed when a throw leaves it.
- **Native exceptions.** Exceptions thrown by native code (the host's libstdc++) are not CLR exceptions and are not caught.
- **The IR is a subset.** Classes with virtual dispatch, variadic calls and `sret` need more emitter work (above).
  `cf2i` (a checked float-to-int conversion) and volatile stores (`store.v`) are refused too. Floating-point arithmetic
  is not translated yet: the emitter has `fneg` only, so `fadd`, `fdiv` and float comparisons (`lt.f`) are refused.
- **Function addresses of undefined functions.** `&"f"` is the function's linker field: a function the unit defines is
  its `ldftn` (set at `Init`), and any other name is `dlsym`'d, which gives null for a name not in the process. A pointer
  to a libc function is therefore a native address, and calling it through `calli` uses the managed convention, which
  is wrong for it. Calls through such a pointer are not supported; calls through pointers to the unit's own functions
  are.

## Next steps, in order

1. `byval` and aggregate values, and the variadic calls (they carry most of the refusals).
2. Typeinfo objects for the thrown and caught types, so catch clauses can be selected and checked by type.
3. Cleanups: translate the destructor calls of the `try` block's objects to `finally` (or `fault`) regions.
4. `sret` and aggregate values (C++ classes passed or returned by value).
