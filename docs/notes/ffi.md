# nfcffi: calling C compiled at run time (`lib/ffi`)

Status: **Milestones 1 to 3, experimental.** A C source text is compiled with `nfcxx -shared` into a cached shared object and
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

## Declarations (Milestone 2)

`Ffi::declarations(file, dialect)` lists the functions a source declares, with their signatures, read from the
front end (`scripts/libclang-cursors`, the libclang-edg shim's cpfe):

```cpp
for (const nfcffi::Declaration& d : ffi.declarations("/usr/include/string.h")) {
  // d.name "strlen", d.return_type "size_t", d.param_decl(0, "s") "const char *s"
}
```

- **Records.** `be/nfcxx_decl.c` writes one `sig` record after each free function's record: its return type, a
  variadic flag and each parameter type spelled as a C declaration with `@` where the name goes (`int (*@)(int)`).
  The printer is EDG's type IL (qualifiers, typedef names, enums, `_Bool`, `long double`, function pointers, arrays
  decayed to pointers in parameters). `scripts/libclang-cursors --c` reads the file as C (the default for
  `Dialect::C`); `Dialect::Cxx` reads it as C++, where overloads are listed and flagged `overloaded`.
- **Headers.** `NFCXX_DECL_ALL=1` lists the declarations of every file the source includes, system headers too, not
  only the primary file. `Ffi::declarations` sets it.
- **Spelling in C vs C++.** C keeps a top-level `const` (`char * const p`); C++ drops it. C drops `restrict`. Array
  sizes are not kept (`int (*)[]`); the ABI is the same. An anonymous struct or enum has no spelling, so its function
  is listed without a signature, and `declarations` omits it.
- **Scope.** Free functions only: members, functions in namespaces and templates are not returned. Macros are not
  seen (the preprocessed text is what the front end reads). The C library's `div` is the global C function, not the
  namespace-std overload that C++ mode also declares.
- **The libclang shim** skips `sig` records (`lib/libclang-edg/clang_edg.c`); its differential test is unchanged.
- **Tests.** `tests/ffi/host.cpp` checks the spellings of `tests/ffi/decls.h` (qualifiers, arrays, function pointers,
  typedef and enum names, `_Bool`, variadic, empty prototypes), the C library's headers (`strlen`, `qsort`, `div`,
  `snprintf`), an overload set in C++ mode, a header that does not parse, and a missing tool. `tests/ffi/run.sh` builds
  the front end when it is missing (`scripts/setup-libclang-edg.sh`, a few minutes).

## Calls by name (Milestone 3)

`Ffi::load(header, source, only)` compiles the header, then `source`, then one wrapper per callable declaration into one
shared object; `Library::call(name, args)` calls by name with runtime-typed `Value`s:

```cpp
nfcffi::Library lib = ffi.load("/abs/dyn.h", read_text("dyn_impl.c"));   // only = {} wraps every callable function
nfcffi::Value r = lib.call("add_int", {Value::of_signed(4), Value::of_signed(5)});   // r.as_signed() == 9
lib.callable("vec_add");   // false: a struct by value
```

- **Kinds.** The front end writes a `kinds` record per function (`be/nfcxx_decl.c`, `nf_kind`): one letter for the
  return type and one per parameter. `i` signed integer, `u` unsigned integer (`bool` too), `f` float or double, `p`
  pointer or array, `v` void, `x` anything else. `Declaration::return_kind` and `param_kinds` carry them.
- **Wrappers.** `void nfcffi_call_NAME(void **a, void *r)` converts each argument from `a[i]` (a `long long`, an
  `unsigned long long`, a `double` or a `void *`, by kind) to the declared parameter type in the cast, calls `NAME` and
  stores the result by kind. The types are spelled by the declarations' abstract types, so the header is what
  defines them: the wrapper is compiled with it.
- **Conversions.** Signed and unsigned integers convert to each other, and integers convert to `float`/`double`. A
  pointer parameter takes a pointer or the integer 0. Any other kind is an `Error` that names the argument.
- **Not callable** (listed by `declarations`, `callable` is false): a struct, union or enum-by-value part that is not an
  integer, `long double`, 128-bit integers, variadic functions, and overload sets. Calling them throws `Error`.
- **Value.** `Value::of_signed`, `of_unsigned`, `of_float`, `of_pointer`; the accessors throw `Error` on another kind.
- **Tests.** `tests/ffi/host.cpp` `check_library`: the callable/not-callable split on `dyn.h` (structs, a variadic
  function), integer and floating conversions, a pointer argument, a host callback through a pointer, arity and kind
  errors, and `strlen` from `<string.h>` loaded with a filter. 68 checks on both backends.
- **Limits.** The whole header goes into one translation unit, so one wrapper that does not compile fails the load:
  use `only` for the functions you need. A function declared in the header but defined nowhere fails the `dlopen`
  (`RTLD_NOW`), so every referenced function must be defined by the header's libraries or by `source`.

## Not yet (Milestone 4)

- **Variadic functions** (`printf`) cannot be called by name: the wrapper cannot pass a runtime number of arguments.
- **Structs by value and in results** need their layout as C passes them; the kinds stop at scalars.
- **ABI.** The checks above cover the SysV x86-64 cases the tests use. Other targets are not covered.
- **Host and module compiler.** The module must be built by the same nfcxx backend as the host for C++ types to match;
  the test runs both with the same backend.

## Plan

1. (done) The C++ API over the compile and cache path, with the tests above.
2. (done) Declarations from headers: typed `sig` records, `Ffi::declarations`, C and C++ dialects.
3. (done) Calls by name: kinds per declaration, wrappers compiled with the header, `Library::call` with `Value`s.
4. A Python binding through `nfcpoly`, which already runs Python from C++ (`docs/notes/poly.md`). Structs by value and
   variadic calls remain open.
