# nfcffi: calling C compiled at run time (`lib/ffi`)

Status: **Milestones 1 to 7 (callbacks), experimental.** A C source text is compiled with `nfcxx -shared` into a cached shared object and
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
  pointer or array, `v` void, `s` struct, union, `long double` or 128-bit integer (as bytes), `x` anything else. `Declaration::return_kind` and `param_kinds` carry
  them.
- **Wrappers.** `void nfcffi_call_NAME(void **a, void *r)` converts each argument from `a[i]` (a `long long`, an
  `unsigned long long`, a `double` or a `void *`, by kind) to the declared parameter type in the cast, calls `NAME` and
  stores the result by kind. The types are spelled by the declarations' abstract types, so the header is what
  defines them: the wrapper is compiled with it.
- **Conversions.** Signed and unsigned integers convert to each other, and integers convert to `float`/`double`. A
  pointer parameter takes a pointer or the integer 0. Any other kind is an `Error` that names the argument.
- **Structs and unions by value** travel as bytes. Each wrapper casts its argument with `*(T *)a[i]` and stores a struct
  result with `*(T *)r = ...`, so the C compiler applies the ABI. A layout function, `nfcffi_layout_NAME`, reports
  `sizeof` for each struct position; `Library::call` checks the size of each struct argument against it and allocates
  the result buffer. The host's struct must have the C layout (a C++ struct with the same members, in the same order).
- **Variadic functions** (`snprintf`, a declaration with `...`) are callable with extra arguments. Each extra argument
  takes the C default promotion of its `Value`: an integer as `long long`, a float as `double`, a pointer as a pointer.
  The callee's format must match them, as in C. The fixed arguments must be scalars. The first call with a new sequence
  of extra kinds compiles a wrapper for it (the header and source again, cached like any other build), so later calls
  with the same sequence are direct.
- **Long double and 128-bit integers** travel as bytes, like a struct: `Value::of_bytes` of `sizeof` bytes (the x87
  80-bit format in the first ten bytes of a `long double`). Tested in `tests/ffi/wide.h`.
- **Not callable** (listed by `declarations`, `callable` is false): overload sets, and any other kind the table lists as
  `x` (for example other float kinds). Calling them throws `Error`. A callback with a struct, a variadic signature or a
  pointer-to-pointer result is a plain pointer: pass a C function pointer, not a host callable.
- **Value.** `Value::of_signed`, `of_unsigned`, `of_float`, `of_pointer`, `of_bytes(p, n)`; the accessors throw `Error`
  on another kind.
- **Tests.** `tests/ffi/host.cpp` `check_library` (variadic: `snprintf` with integer, string and double extras, and a
  second sequence): the callable/not-callable split on `dyn.h` (structs, a variadic
  function), integer and floating conversions, a pointer argument, a host callback through a pointer, arity and kind
  errors, `strlen` from `<string.h>` loaded with a filter, and structs by value (`vec_add`, `big_make`, in and out, with a
  size and a kind error). 73 checks on both backends.
- **Limits.** The whole header goes into one translation unit, so one wrapper that does not compile fails the load:
  use `only` for the functions you need. A function declared in the header but defined nowhere fails the `dlopen`
  (`RTLD_NOW`), so every referenced function must be defined by the header's libraries or by `source`.

## Callbacks (Milestone 7)

A parameter that is a pointer to a function with scalar parameters and result (`iufp`, result also `v`, not variadic) has
kind `c`. The front end writes a `cb` record for it (`be/nfcxx_decl.c`, `nf_emit_cb`): the callback's result, its kinds
and its parameters. A callback that is variadic, or has a struct parameter, keeps kind `p` (a plain pointer).

- **Trampolines.** For each callback parameter the generated C has a context variable, a raw-pointer variable and a
  trampoline with the callback's declared signature. The trampoline stores its arguments canonically (`long long`,
  `unsigned long long`, `double`, `void *`), calls the host dispatcher `nfcffi_host_dispatch` with its context, and
  returns the result converted to the declared type.
- **The argument.** A host callable is passed as `Value::of_callable(fn)`; `fn` takes the arguments as `Value`s and
  returns a `Value`. A C function pointer is passed as `Value::of_pointer` and goes straight through. `Value()` with
  an integer 0 (or a null pointer) is nil. The wrapper picks the trampoline when the context is set, and the raw
  pointer otherwise.
- **Exceptions.** A callable's exception cannot cross the C frames, so the dispatcher catches it and `Library::call`
  rethrows the first one after the C call returns.
- **Tests.** `tests/ffi/host.cpp` `check_library` (callbacks): a callable that multiplies, a callable that writes into a
  host list, an int/double callback, a nil callback, a wrong-kind argument, and an exception rethrown.

## Python (Milestone 6)

`lib/ffi/nfcffi_poly.{hpp,cpp}` binds the library into an `nfcpoly::Context` (`nfcffi::bind_poly(ctx)`), so Python, and
every other language nfcpoly has, can load a header and call it:

```cpp
nfcpoly::Context ctx;
nfcffi::bind_poly(ctx);
ctx.eval<long long>("python", "lib = ffi_load('/abs/dyn.h', src_text, ['add_int'])\nlib.call('add_int', [4, 5])");   // 9
```

- `ffi_load(header, source, [names])` returns an `FfiLibrary`. The names are optional (the default wraps every callable
  function of the header; a function that does not compile in the wrappers fails the whole load, so name what you need).
- `lib.call(name, [args])` and `lib.callable(name)`. An argument is an integer, a boolean, a float, a string (a C string
  for the call), nil (a null pointer, or 0), or an array of integers 0..255 (the bytes of a struct or union).
- A result is an integer, a float, nil (a null pointer), or an array of bytes (a struct or union). A pointer result is its
  address as an integer.
- Errors reach the script as script errors (an `Error` of the library is a `RuntimeError`-like error in each language).
- Test: `tests/ffi/poly_host.cpp`, with CPython (`python3-config`); `tests/ffi/run.sh` builds it when the CPython
  development files are present and skips it otherwise.

## Not yet

- **ABI.** The checks above cover the SysV x86-64 cases the tests use. Other targets are not covered.
- **Host and module compiler.** The module must be built by the same nfcxx backend as the host for C++ types to match;
  the test runs both with the same backend.

## Plan

1. (done) The C++ API over the compile and cache path, with the tests above.
2. (done) Declarations from headers: typed `sig` records, `Ffi::declarations`, C and C++ dialects.
3. (done) Calls by name: kinds per declaration, wrappers compiled with the header, `Library::call` with `Value`s.
4. (done) Structs and unions by value, as bytes with the C layout.
5. (done) Variadic calls: a wrapper per sequence of extra argument kinds, compiled on first use.
   (done) Long double and 128-bit integers, as bytes. (done) Callbacks: a host callable behind a function pointer.
6. (done) Python through `nfcpoly` (`nfcffi_poly.cpp`): `ffi_load` and `FfiLibrary.call`, with the same argument rules.
