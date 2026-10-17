# Path B to CIL: C++ exceptions as CLR exceptions (spike)

`scripts/pathb-cil file.cpp -o x` compiles a C++ file through Path B's IR and runs it as a .NET 8 assembly. It is the
spike of the route chosen for C++ exceptions on CIL (see `docs/notes/cil.md`, "Not supported"): the exception handling
of Path B's IR is turned into CLR `try`/`catch`, not into EDG's `setjmp`/`longjmp` runtime.

## Pipeline

```
C++ --pathb-dump --ir--> Path B IR --pathb-cil-emit.py--> JSON fragment --cil-link.py--> CIL --ilasm--> x.dll (+ launcher)
```

- `scripts/pathb-cil-emit.py` reads the IR text (its format: `docs/notes/pathb-stage2.md`) and writes a fragment, the
  same format `qbe2cil.py` writes, so `cil-link.py` links both: one class `Prog`, globals as `addr_<name>` fields,
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

Coverage of the existing Path B IR corpus (`tests/pathb-ir/*.ir`, 62 files): **12 translate**, 50 are refused. The
`bytes` initializers (string literals and typeinfo names: `(data ...)` string constants become data, and `bytes` copies
them), `index` and `bounds` (`abort()` when the index is not below the bound, as QBE's abort) translate now. The
refusals, by count:

- 9: taking the address of a function (`&"f"`); 7: variadic expressions; 3: `(ellipsis)` parameters
- 6: `byval`/aggregate values; 2 indirect calls; 2 each: `trap`, `pdiff`, `load.v`, `cshr`, `crem`, `bitfield`
  initializers; 3: `std::float16_t`; the rest are one-offs (`barrier`, `fneg`, `cshl`, `cf2i`, `cdiv`, `bfload`, `alloca`)

## Limits of this spike (each a refusal or a known wrong result)

- **One catch clause only.** The catch assumes clause 1. Selecting among clauses (and checking the thrown type) needs
  typeinfo objects: EDG's `_ZTI*` are extern here (libc++/libstdc++ define them on hosted builds), so the emitter cannot
  compare them. A try with several clauses is refused. A single catch of a different type than the one thrown is not
  detected: it is a wrong result, so it must be fixed before this route is used on real programs.
- **No destructors during unwinding.** EDG's cleanup tables are not translated. Objects with destructors in the `try`
  block are not destroyed when a throw leaves it.
- **Native exceptions.** Exceptions thrown by native code (the host's libstdc++) are not CLR exceptions and are not caught.
- **The IR is a subset.** Classes with virtual dispatch, function addresses, variadic calls and `sret` need more emitter
  work (above).

## Next steps, in order

1. Function addresses (`&"f"`), `byval` and aggregate values, and the variadic calls (they carry most of the refusals).
2. Typeinfo objects for the thrown and caught types, so catch clauses can be selected and checked by type.
3. Cleanups: translate the destructor calls of the `try` block's objects to `finally` (or `fault`) regions.
4. `sret` and aggregate values (C++ classes passed or returned by value).
