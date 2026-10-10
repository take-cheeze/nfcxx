# nfceval: evaluating C++ at run time with bound host objects

`lib/eval/nfceval.hpp` + `nfceval.cpp` let a program compiled with nfcxx evaluate C++ source text while it runs,
with named host objects and functions visible to the snippet:

```cpp
#include "nfceval.hpp"
#include "vec3.hpp"                                   // the user's own types

nfceval::Engine eng;                                  // finds nfcxx and a cache directory
eng.include("vec3.hpp");                              // snippets need the declarations of bound types
eng.add_flag("-I/path/to/headers");
int counter = 0; Vec3 pos{1, 2, 3};
eng.bind("counter", counter);                         // the snippet sees `int& counter`
eng.bind("pos", pos);                                 // ... and `Vec3& pos`
eng.bind_fn("scale", &scale);                         // `double scale(double)`; lambdas (also capturing) work
eng.bind_method("Vec3_len2", &Vec3::len2);            // `double Vec3_len2(const Vec3&)`
int r    = eng.eval<int>("counter += 2; return counter * pos.x;");
double d = eng.eval<double>("scale(pos.y)");          // a bare expression is wrapped as `return (expr);`
eng.eval_void("pos.x = 42;");
```

Build the host with `nfcxx -I lib/eval -rdynamic host.cpp` (see "Linking the host" below). Tests: `tests/eval/run.sh`
(both backends, wired into CI).

## Mechanism

1. `Engine::generate` writes one translation unit: default includes (`<new> <exception> <stdexcept> <string>
   <cstdio> <cstdlib> <cstring> <cmath> <type_traits>`), the user prelude, one file-scope function per bound
   function, and `static R nfceval_body(void* const* t)` whose first lines declare each bound object as a reference
   (`typedef T nfceval_T_x; nfceval_T_x& x = *static_cast<nfceval_T_x*>(t[i]);`) followed by the snippet. An
   `extern "C" int nfceval_entry(table, result, err, errlen)` calls the body inside `try`, constructs the result in
   host-provided storage, and turns an exception into a status plus message.
2. Object addresses and function thunks are **not** in the source: the host passes them in a table of `void*` on every
   call. So the source (hence the cache key) depends only on the bound names, types, prelude and snippet; the same
   snippet with a different object of the same type is a cache hit. Rebinding a name to another type changes the
   source and recompiles.
3. The source is hashed (two FNV-1a 64 passes, 32 hex digits, plus driver path, extra flags and `NFCXX_BACKEND`) and
   compiled as `nfcxx -shared [flags] <cache>/nfceval-<hash>.cpp -o <hash>.so.tmp` (stdout and stderr to a file),
   then renamed into place. An existing `.so` is just loaded: a second `Engine`, or a second run of the program,
   does not compile.
4. `dlopen(RTLD_NOW | RTLD_LOCAL)` once per distinct source per engine; handles stay open until the destructor
   `dlclose`s them. `nfceval_entry` is looked up with `dlsym`.
5. Bound functions are called through `R (*thunk)(void* state, A...)` pointers with the argument types spelled in the
   source; the host side of the thunk calls the stored callable (a heap copy kept by the engine).

Type names come from `__PRETTY_FUNCTION__` (`T = ...`), which the front end prints in GCC form, for example
`std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>>`; that is a valid spelling in the
snippet. `bind(name, obj, "spelling")` and `eval<R>(code, "spelling")` override it.

## Snippet forms

- Statements with `return`: used as the function body.
- No `return` and the last top-level statement is an expression without `;` (`"a + b"`, `"x = 3; x * 2"`): that
  expression becomes `return (expr);`. A snippet ending in `;` or `}` is statements only; for `eval<R>` with
  `R != void` that throws `RuntimeError("snippet did not return a value")`. For `eval_void` a trailing `;` is added
  when missing.
- Line numbers are preserved: the snippet starts at `#line 1 "snippet"`. The compiler (EDG) reports `"snippet",
  line 2: error: ...`, so those numbers are lines of the text given to `eval`. Errors in the generated
  scaffolding or the prelude name the generated file in the cache directory (kept for inspection).

## Errors

- `nfceval::CompileError` (derives `Error`, `std::runtime_error`): the snippet did not compile; `what()` is
  `nfceval: compile failed (driver exit N)` plus the compiler's stderr. Also used for a compile timeout.
- `nfceval::Error`: the driver cannot be run, cache directory problems, `dlopen` failure, unspellable types, bad names.
- `nfceval::RuntimeError`: the snippet threw. nfcxx's exceptions are EDG's runtime (setjmp-based, one EH stack per
  shared object), not the host's: an exception cannot unwind across the host/snippet boundary. The generated entry
  function catches inside the snippet's object (`std::exception` and `...`), copies `what()` (or
  `"unknown exception"`) and the host rethrows it as `RuntimeError`. The original exception type and object are
  lost. Throwing from a *bound host function* works the other way round: it is thrown in the host runtime and
  is expected to unwind to the nearest host handler without running the snippet's destructors (untested);
  avoid it, or catch inside the bound function.
- Exceptions raised by libstdc++ itself (`std::string::at`, `new` failure, ...) use the system unwinder, which the
  snippet's EDG handlers do not see (a pre-existing nfcxx limitation, not specific to this library): they end in
  `terminate`.

## Configuration

| what | how | default |
|---|---|---|
| driver | `set_driver`, env `NFCXX`, `-DNFCEVAL_DEFAULT_DRIVER="path"`, `<repo>/nfcxx` found from `__FILE__`, `nfcxx` on PATH | in that order |
| cache dir | `set_cache_dir`, env `NFCEVAL_CACHE` | `$TMPDIR` (or `/tmp`)`/nfceval-cache-<uid>`, mode 0700 |
| backend | environment `NFCXX_BACKEND=gcc|qbe`, or `add_flag("--backend=gcc")` | the driver's default (qbe) |
| flags | `add_flag("-I...")`, `-D...`, ... | none |
| compile timeout | `set_compile_timeout(seconds)`, 0 disables | 300 s, the compiler's process group is killed |

`#include "x.hpp"` in a prelude is resolved against the generated file's directory (the cache) and the `-I` flags,
so give `add_flag("-I<dir>")` or an absolute path. The cache directory must be owned by the user and not group/world
writable (shared objects in it are executed); otherwise the engine refuses to use it. The cache is never cleaned;
delete it freely (not while another process is compiling).

## Linking the host

- **Out-of-line members** of bound types (and any host function the snippet names without a binding) are resolved by
  the dynamic linker against the host executable, so link it with `-rdynamic` (`nfcxx -rdynamic ...`). Inline
  members need nothing. `bind_method`/`bind_fn` avoid the requirement: they pass the member through a thunk.
- With glibc older than 2.34 add `-ldl` (nfcxx's driver cannot currently find `libdl.so` for `-ldl`; use a newer glibc).
- The library is an ordinary second translation unit: compile `nfceval.cpp` together with the host
  (`nfcxx -I lib/eval -rdynamic host.cpp lib/eval/nfceval.cpp -o host`) or as an object (`nfcxx -c`) linked later.
  Several nfcxx-compiled objects that use libstdc++ templates such as `std::string` link, see `multi-tu.md`
  (this used to fail with duplicate `std::allocator<char>` members on gcc and `__cmp_cat_id` on qbe, so the
  library had to be `#include`d into the host's single translation unit; that still works and is tested by
  `tests/eval/host_single.cpp`).
- Host and snippet must be built by the same compiler and flags (same backend, same EDG, same libstdc++ headers):
  they exchange `std::string`, class objects and function pointers directly. Run the engine with the same
  `NFCXX_BACKEND` as the host was built with; an extra `--backend=` flag selects another but only works for types
  whose layout and calling convention do not differ (they do not today, both backends emit the same C, but this is
  not guaranteed).

## `nfcxx -shared`

Added to the driver for this library: `-shared` (implies `-fPIC`), `-fPIC`/`-fpic`, `-rdynamic`. `-fPIC` and
`-rdynamic` are given to the C compiler step and the link as `--c_to_obj_option`; `-shared` is given to the link
through `EDG_OBJ_TO_EXEC_DEFAULT_OPTIONS` (which replaces the options eccp uses for its link command). QBE output is
position independent already (`-fPIC` is ignored by `scripts/qbe-cc`). C-only inputs work as well
(`nfcxx -shared a.c -o a.so`). EDG's runtime (`__throw`, `__curr_eh_stack_entry`, ...) is linked into each shared
object, which is why exceptions do not cross the boundary. Static constructors and destructors of globals in the
prelude run on `dlopen` / `dlclose` (tested). Test: `tests/eval/probe*.{c,cpp}` via `tests/eval/run.sh`.

QBE side: `scripts/qbe-prep.rb` maps `__builtin_memchr` to `memchr` (needed by `std::string::find` in the
header, like the existing `memcpy`/`memcmp` mappings).

## Safety: there is no sandbox

`eval` compiles and runs arbitrary native C++ **inside the host process** with the host's privileges. A snippet can
read and write any memory, call any libc function, `exit`, loop forever or crash the process. Do not evaluate text
from an untrusted source. There is no run-time timeout: only the compile step has one (a snippet that loops forever
hangs the host; run the engine in a worker process if that matters). The compiler is executed from `$NFCXX`/`PATH`
and the shared objects from the cache directory; both are trusted inputs (hence the ownership check on the cache).
Do not share a writable cache between users.

## Limitations

- Types and signatures are spelled by the generated source: a bound type must be named (not a lambda or
  unnamed/local type; give a spelling or bind a `std::function`-like named type) and its declaration must be
  visible to the snippet (`include`/`prelude`). Template instances are fine when their definitions are visible
  (`std::vector<int>`), and are spelled as the front end prints them.
- `bind_fn`: one non-template call operator, non-variadic, parameters and return type spellable (so no generic
  lambdas, no C varargs like `printf`; wrap them). Captures are fine (the engine copies the callable and keeps it
  alive; captured references must outlive the engine). Overloads of one name are not supported (one binding per name).
- `bind` passes the address of the object: it must outlive every eval that uses it, Bound references are plain references in the snippet (no pointer to rebind).
- Results: `eval<R>` needs a non-reference `R` whose spelling is valid in the snippet and alignment at most
  `max_align_t`. The value comes from `new (res) R(body())`, so it is converted like a function return.
- One eval at a time per engine; not thread-safe; re-entrant evals from a bound function are untested.
- Names: bound names are plain identifiers declared in the body (objects) or at file scope (functions). They can
  clash with names from the prelude or headers.
- The generated source contains no host addresses, but behaviour depends on the host objects' layout being the
  same as in the snippet's view of the type (same header); keep the declarations in one header.
- Compile cost: each new source runs the whole nfcxx pipeline (seconds per snippet with the libstdc++ headers); the cache makes repeats free. Pre-warm by evaluating once, or keep a directory of shared objects.
- `alignas` and `std::make_shared`/atomics in the library header are avoided on purpose: cproc rejects `aligned`
  attributes on locals and has no `__atomic_thread_fence`, so the library uses `operator new` and a
  `unique_ptr<void, deleter>` instead.
