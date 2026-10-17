# The CIL backend: C programs as .NET assemblies

`NFCXX_BACKEND=cil nfcc x.c -o x` compiles C to a .NET 8 assembly and runs it with `dotnet`. It is for C-like code:
structs, pointers, arrays, function pointers, switch, goto, floats, `printf` and the libc calls a program makes. It is
not a managed language: C pointers stay raw addresses in unmanaged memory, and the CLR's GC does nothing for them.

## Pipeline

```
C --cpp--> prep (qbe-prep.rb) --cproc--> QBE IL --qbe2cil.rb--> JSON fragment (.o) --cil-link.py--> CIL text
   --ilasm--> x.dll  +  x.runtimeconfig.json  +  x (launcher: exec dotnet x.dll "$@")
```

- `scripts/cil-cc` is the compiler wrapper: it sets `NFCXX_CIL=1` and runs `scripts/qbe-cc`, which does the
  preprocessing, `qbe-prep.rb` and cproc as for the QBE backend. With `NFCXX_CIL` set it writes a fragment instead of
  running QBE, and its link step is `cil-link.py`.
- `scripts/qbe2cil.rb` (a port of the former `qbe2cil.py`, see `docs/notes/mruby-scripting.md`) turns one translation unit's QBE IL into a fragment: the method bodies as CIL text, the
  functions, data, the calls with their signatures, and the global symbols the unit uses.
- `scripts/cil-link.py` links the fragments into one static class `Prog`, writes the CIL, runs ilasm, and writes the
  launcher. Shim source is built with `cc` when a program calls a variadic function (below).
- `scripts/setup-cil.sh` fetches ilasm (`runtime.linux-x64.microsoft.netcore.ilasm` 10.0.13, from NuGet) into
  `build/cil/ilasm`. ilasm 10 writes assemblies that run on .NET 8. The .NET 8 runtime (or later) must be on `PATH`
  to run a program; the SDK is not needed.

## Memory and calls

- A pointer is an `int64` address. Loads and stores are `ldind`/`stind` through `conv.u`, on memory from `calloc`.
- Each QBE temporary is an IL local. A phi becomes a copy on each edge, batched on the evaluation stack, so the
  copies are a parallel assignment. cproc leaves out jumps to the next block: those edges are added.
- Stack slots (`alloc`) come from one `localloc` per call. `alloca` (a run-time size) is `localloc` too.
- Aggregates: a parameter is the caller's address, and the callee copies it into its own frame on entry. An aggregate
  result is a slot in the caller's frame whose address is passed first; `ret` copies into it.
- Globals are static fields `addr_<name>`. `Init` callocs each data symbol, fills in the initializers (including
  addresses of other symbols), and runs the constructors. A symbol no unit defines is found with `dlsym`.
- Function addresses are `ldftn` values; indirect calls are `calli` (managed convention, so only calls from managed
  code through them work).
- A function no unit defines is a P/Invoke to `libc.so.6` (`libm.so.6` for the math functions).
- Symbols a unit does not export are renamed `name@unit`, so two files can each have a `static` function of one name.
- `main` gets `argc` and `argv`: `argv[0]` is the program name and the rest are the command-line arguments.

**Variadic calls.** .NET cannot P/Invoke a C variadic function, and the SysV ABI needs `%al` set to the number of
vector registers used; without it `printf` drops its floating-point arguments. So a variadic call goes through
`nfcxx_vcall` in `libnfcxx_va.so` (built next to the output with `cc`). The shim calls the named function through a
variadic prototype, which sets `%al`. Up to six integer and eight floating arguments go in registers, and up to eight
more integer arguments go on the stack in order.

## Tests

`tests/cil/run.sh` (wired into ci.yml, with `actions/setup-dotnet` 8.0) compiles and runs:

- `cases/*.c`: nine programs with exit status and stdout checked against `*.out`. They cover recursion, a loop, function
  pointers, integer and float arithmetic at each width and signedness, strings and `snprintf`, `switch` and `goto`,
  struct copies and returns, unions, bit-fields, `alloca`, static locals and a static table, a heap list, and
  `#include <stdio.h>`, `<stdlib.h>`, `<string.h>`, `<math.h>`, with command-line arguments.
- `multi/statics`: two files with a `static` function and a `static` local of the same name, and an `extern` global.
- `errors/variadic_def.c`: a defined variadic function is refused with a message, not miscompiled.

The expected values were checked by hand against C semantics before they were written down.

## Not supported (each is an error or a known wrong result)

- **Defined variadic functions** (`va_start`/`va_arg`): refused with an error. Calls to variadic functions work.
- **Callbacks from native code**: a comparison function given to `qsort`, a `setjmp`/`longjmp` pair, and anything else
  that calls a function pointer from native code. A managed function pointer is not callable from native code, so these
  crash. `qsort` needs `[UnmanagedCallersOnly]`-style callbacks, which this backend does not emit.
- **Variadic calls** with more than 14 integer or 8 floating arguments, or with a floating result; indirect variadic
  calls.
- **Aggregates** through indirect calls, and variadic calls returning aggregates.
- **Inline assembly, `long double`, `_Complex`, thread-local variables**: cproc has no support for them.
- **Non-exported duplicates**: two units that both define the same exported symbol are a link error, as in C.
- **`-S`** (assembly output): not supported by this backend.
- **Performance**: not measured. Every memory access is an `ldind`/`stind` on raw memory; the JIT compiles them, but
  the code is not tuned for the CLR.

## Relation to the other backends

The QBE and gcc backends are unchanged except for the `qbe-cc` branch that selects the CIL path. The shared front-end
steps (the preprocessing, `qbe-prep.rb`, cproc) are the same, so a C program that compiles for QBE reaches this backend
with the same IL. The output is not verified CIL (C's memory model is not the CLR's), so it runs only where the native
memory it touches is valid: the same assumption as the QBE and gcc binaries.
