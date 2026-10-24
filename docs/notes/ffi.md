# nfcffi: calling C compiled at run time (`lib/ffi`)

Status: **Milestone 1, experimental.** A C source text is compiled with `nfcxx -shared` into a cached shared object and
loaded; its functions, and the C library's, are called through C++ function types written at the call site. The
design is DragonFFI's idea (a C library called from a host at run time, without writing bindings by hand), without
its header parser and without libffi.

```cpp
#include "nfcffi.hpp"

nfcffi::Ffi ffi;                                           // finds nfcxx, a cache directory
nfcffi::Module m = ffi.compile("int add(int a, int b) { return a + b; }");
auto add = m.function<int(int, int)>("add");              // the signature is spelled in C++
int r = add(4, 5);                                         // 9
auto strlen_ = nfcffi::process_function<size_t(const char*)>("strlen");   // from the C library
```

## Mechanism

1. `Ffi::compile` hashes the source with the driver path, the flags and `NFCXX_BACKEND` (the nfceval hash). The source is
   written to `<cache>/nfcffi-<hash>.c` and built as `nfcxx -shared [flags] <that file> -o <tmp>`, then renamed into
   `<hash>.so`. An existing `.so` is loaded without running the compiler.
2. `dlopen(RTLD_NOW | RTLD_LOCAL)`. `Module::function<R(A...)>(name)` is a `dlsym`, copied into a typed
   `R (*)(A...)`. The call is an ordinary C call: no thunks, no marshaling. The types are the caller's, so a wrong
   signature is a wrong call, as with any C function pointer.
3. `process_function` does the same with `dlsym(RTLD_DEFAULT, ...)`, which finds the C library and anything the host
   exports.

The build and cache helpers are nfceval's (`lib/eval/nfceval_build.hpp`), so driver lookup, the per-user cache
directory (mode 0700, owned by the user), the compile timeout and the child process group work the same way
(`docs/notes/eval.md`).

## API

| name | what |
| --- | --- |
| `nfcffi::Ffi(driver = "")` | Driver: `$NFCXX`, then `<repo>/nfcxx`, then `nfcxx` on PATH. |
| `add_flag`, `set_cache_dir`, `set_compile_timeout` | As for nfceval; the cache is `$NFCFFI_CACHE` or `$TMPDIR/nfcffi-cache-<uid>`. |
| `Module Ffi::compile(source)` | Build and load. `CompileError` (with the driver's output) when the source does not compile. |
| `Module::function<R(A...)>(name)` | Typed address of a symbol. `Error` when there is none. |
| `process_function<R(A...)>(name)` | Typed address of a symbol of the running program or the C library. |
| `Function<R(A...)>` | `operator()` and `get()`. Valid while the `Module` lives (or always, for process functions). |

`Module` is move-only and `dlclose`s on destruction.

## What is covered by `tests/ffi/run.sh`

`tests/ffi/host.cpp` compiles `tests/ffi/lib.c` with nfcxx and checks 23 results on both back ends: ints, `float` and
`double` arguments, a struct of two doubles passed and returned in registers, a 24-byte struct returned through a hidden
pointer, a small struct returned in a register, a host function called back from C through a function pointer; from
the C library, which gcc compiled: `div` and `ldiv` (struct returns in registers), `qsort` with a host comparator,
`strlen`; a missing symbol and a compile error give `Error` and `CompileError`; a moved `Module`; the cache.

## Not yet (Milestones 2 and 3, see the plan)

- **No declarations from headers.** Nothing parses a header; the signature comes from the C++ caller. The libclang
  front end (`libclang-edg.md`) lists declarations of the primary file only and no types, so `cdef` needs a type
  walk in `be/nfcxx_decl.c` first.
- **No dynamic calls.** Without a signature in the caller there is no way to call a function by name with runtime
  types. That needs the per-function wrapper and a type descriptor, which in turn need the type walk.
- **Variadic functions** (`printf`) cannot be spelled as `R(A...)`; the call site would need a fixed signature per use.
- **ABI.** The checks above cover the SysV x86-64 cases the tests use. Other targets and the struct classes
  (non-trivial copy or destructor, which C does not have) are not covered.
- **Host and module compiler.** The module must be built by the same nfcxx backend as the host for C++ types to match;
  the test runs both with the same backend.

## Plan

1. (done) The C++ API over the compile and cache path, with the tests above.
2. Declarations from headers: extend `be/nfcxx_decl.c` with parameter and return types for function declarations,
   and list the declarations of the headers the source includes, not only the primary file. Then `cdef(header)` and
   `Module::functions()` list names and signatures.
3. Dynamic calls: for each function, a generated `void wrap(void** args, void* ret)` with the types from the
   declarations, and a call by name with values of runtime type (the `Value` of nfcpoly is a model).
4. A Python binding through `nfcpoly`, which already runs Python from C++ (`docs/notes/poly.md`).
