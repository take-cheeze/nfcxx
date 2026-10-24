# nfcpoly: scripts in other languages, embedded in a C++ program

`lib/poly` lets a program compiled with nfcxx evaluate source text of **Ruby** (mruby), **Lua**, **Python** (CPython),
**JavaScript** (QuickJS-NG), **Go** (yaegi) and **ast** (Lua syntax, run by the self-specializing AST interpreter of `lib/ast`,
`ast.md`) while it runs, with host objects and functions visible to the scripts and the scripts' values visible to C++: a small
version of GraalVM's polyglot `Context.eval(language, source)` with shared bindings, several languages in one `Context`. Unlike
`nfceval` (`eval.md`) no compiler runs per snippet.

What it is not: GraalVM's partial evaluation, or one heap shared by the languages. Values cross by copy (plain data), or
as handles (a script wrapper around a C++ object, a `Value` rooting a script object), and the C++ side declares what a
script may touch. Each language has its own interpreter.

```cpp
#include "nfcpoly.hpp"
nfcpoly::Context ctx;
ctx.def_class<Vec3>("Vec3").ctor<double, double, double>().field("x", &Vec3::x).method("len2", &Vec3::len2);
Vec3 pos{1, 2, 3};
ctx.bind("pos", pos);                    // `pos` in a script is this very object, in every language
ctx.bind_fn("scale", &scale);            // `scale(2.0)` calls the C++ function
int    r = ctx.eval<int>("ruby", "pos.x = 4; pos.x * scale(2.0)");       // pos.x is 4 in C++ afterwards
double d = ctx.eval<double>("lua", "pos.x + scale(1.0)");
auto   v = ctx.eval<std::vector<int>>("python", "sorted([3, 1, 2])");
auto   s = ctx.eval<std::string>("js", "new Vec3(1, 2, 3).len2().toFixed(1) + '!'");     // "14.0!"
double g = ctx.eval<double>("go", "pos.X() + scale(1.0)");                // Go is typed: pos.X(), pos.SetX(4), NewVec3(1, 2, 3)
Value  f = ctx.eval_value("lua", "function(a) return a * 2 end");
int    n = f.execute(21).as<int>();                                       // 42
```

Build and test: link `nfcpoly.cpp` and the backend of each language you want (a backend registers itself when it is
linked in), plus that language's library:

| Language | backend | library | built by |
| --- | --- | --- | --- |
| Ruby (`"ruby"`, `"mruby"`) | `nfcpoly_mruby.cpp` | `build/poly/<backend>/lib/libmruby.a` | `scripts/setup-poly.sh` |
| Lua (`"lua"`) | `nfcpoly_lua.cpp` | `build/poly-lua/<backend>/lib/liblua.a` | `scripts/setup-poly-lua.sh` |
| Python (`"python"`, `"python3"`, `"py"`) | `nfcpoly_python.cpp` | the system libpython (`python3-config --ldflags --embed`) | `apt-get install python3-dev` |
| JavaScript (`"js"`, `"javascript"`, `"quickjs"`) | `nfcpoly_js.cpp` | `build/poly-js/<backend>/lib/libquickjs.a` | `scripts/setup-poly-js.sh` |
| ast (`"ast"`, `"nfcast"`) | `nfcpoly_ast.cpp` | the six `lib/ast/nfcast_*.cpp` files (`-I lib/ast`) | nothing to build |
| Go (`"go"`, `"golang"`) | `nfcpoly_go.cpp` | `build/poly-go/libnfcgo.so`: yaegi and the bridge of `lib/poly/go`, a cgo shared library | `scripts/setup-poly-go.sh` (Go >= 1.24 and the Go module proxy) |

`tests/poly/run.sh` builds all six for `qbe` and `gcc` and runs `tests/poly/host.cpp` (CI: `ci.yml`); Python is skipped
with a `SKIP` line when `python3-config` or `Python.h` is missing, and Go when Go (>= 1.24, from `$GO`, `PATH` or
`/usr/local/go/bin`), a C compiler for cgo or the Go module proxy is missing. `POLY_LANGS="lua js ast go"` selects languages.

Each backend has a header for raw access to its interpreter next to nfcpoly (`nfcpoly_mruby.hpp`, `nfcpoly_lua.hpp`,
`nfcpoly_python.hpp`, `nfcpoly_js.hpp`, `nfcpoly_go.hpp`): the interpreter's state, and a way to get the script value behind a `Value`. For
JavaScript: `js_context(ctx)` (a `JSContext*`), `js_value(v)` (a new `JSValue` reference to free with `JS_FreeValue`) and
`js_wrap(ctx, jsvalue)` (a `Value` for a raw `JSValue`); `tests/poly/host.cpp` uses them to run `JS_RunGC`, to read a promise's
state, to define a native function with `JS_NewCFunction` and to build a `Value` from a `JSValue`. For Go there is `go_collect(ctx)`: it runs `nfc.GC()`, a full collection of Go's collector followed by the sweep of the weak pointers of the wrappers of host objects, so that the host objects the script dropped are released when it returns (`nfcpoly_go.hpp`).

## Architecture

- `nfcpoly.hpp` (the whole public API, no interpreter header) and `nfcpoly.cpp` are language neutral. C++ values convert to
  and from a neutral `Var` (nil, bool, integer, float, string, array, a registered C++ object, or a handle to a script
  value). `nfcpoly_lang.hpp` is the interface a backend implements: `eval`, `call`, deep conversion of arrays, and the
  declarations (global function, value, live variable, class with methods, properties and constructor).
- A backend converts between `Var` and its interpreter's values, defines what was declared, and registers itself with a
  static `LangRegistrar`. A language's interpreter starts on its first `eval`; everything declared before is replayed into
  it, and later declarations reach the running ones.
- A `Callable` also describes the C++ types of its parameters and result (`Callable::signature`: a `Sig` of `TypeDesc`s, computed
  from the template parameters where the callable is made). Only the Go backend reads it: a statically typed language has to write
  the types of the script-side function down (see "Go: the typed binding model").
- Decoding is shallow (plain data and registered objects convert, everything else becomes a rooted handle); arrays are
  converted when a C++ type asks for one (`std::vector<T>`, `Value::as`), so a script array passed to a `Value` parameter
  keeps its identity.
- Registered C++ objects carry a shared ownership record (`Owned`): the C++ object is deleted when the last script wrapper
  and the last `Var`/`Value` are gone. A handle to a script value is orphaned, not left dangling, when its `Context` goes
  away, so a `Value` outlives its `Context` safely (plain values and co-owned objects keep working; asking the interpreter
  throws `Error`).

## Building the interpreters

All five that need building are checked on both back ends (Go: one library for both); the `ast` engine is C++ and is compiled with the host.

**Ruby: mruby with C++ exceptions.** `scripts/setup-poly.sh` builds mruby 4.0.0 (the pin of `scripts/setup-mruby.sh`) with
its own rake build (`scripts/mruby-rt-config.rb`): `nfcc` is the C compiler, `nfcxx` the C++ compiler and the linker, and
`conf.enable_cxx_exception` is on. In that mode mruby's `MRB_THROW` is a C++ `throw` of an `mrb_jmpbuf*`, and mruby compiles
`src/vm.c`, `error.c`, `gc.c` and the compiler gem's parser and code generator as C++ through generated `*-cxx.cxx`
wrappers; every other file stays C. With nfcxx as the C++ compiler those throws are EDG's exception runtime, the one the
host's `throw` and `catch` use (checked with `nm` on both back ends: exactly those five members of `libmruby.a` reference
`__throw`; no other member references `setjmp` or `longjmp`). Two workarounds: `MRB_USE_VM_SWITCH_DISPATCH` (EDG rejects
mruby's `const void *` computed-goto table when `vm.c` is compiled as C++, `cxx-driver.md`), and
`scripts/mruby-cxx-novolatile.patch` (the only `volatile` in those files is a setjmp guard; cproc cannot store to a volatile,
and a `-Dvolatile=` breaks the hosted libstdc++ headers). The gems are the compiler, sprintf, the `*-ext` gems, `mruby-set`,
`-error`, `-metaprog`, `-math`, `-bigint`, `-struct`: no `mruby-io`, `-exit`, `-time` or `-sleep`.

**Lua: ldo.c as C++.** `scripts/setup-poly-lua.sh` builds Lua 5.4.9 (the pin of `tests/realworld/run_lua.sh`) into
`liblua.a`. Lua raises an error with `longjmp`, or, when the file is compiled as C++, with `throw`; `ldo.c` is the only file
that does either, so it is built by nfcxx as C++ (in a generated wrapper that includes it inside `extern "C"`) and every
other file by nfcc as C. Checked with `nm`: only `ldo.o` references `__throw`. `scripts/lua-cxx-novolatile.patch` drops the two
volatile members that `ldo.c` writes (`lua_longjmp.status`, and `CallInfo.u.l.trap`, which only a signal handler could race
with). The libraries a script gets are base (without `dofile` and `loadfile`), coroutine, table, string, math and utf8: no
`io`, `os`, `package` or `debug`.

**JavaScript: QuickJS-NG in plain C.** `scripts/setup-poly-js.sh` builds QuickJS-NG v0.17.0 (the commit of tag `v0.17.0` is
the pin) into `libquickjs.a` from `quickjs.c`, `dtoa.c`, `libregexp.c` and `libunicode.c`, all as C by `nfcc`. QuickJS reports
errors as return values (`JS_EXCEPTION`), so no C++ build is needed (checked with `nm`: neither archive references `setjmp`,
`longjmp`, `__throw` or `_Unwind_*`). Not built: `quickjs-libc.c`, `qjs.c`, `qjsc.c`, so a script has no `std`, no `os`, no
files, no module loader, no `console` and no timers; it has every standard intrinsic of `JS_NewContext` (`JSON`, `RegExp`,
`Date`, `Proxy`, `Map`/`Set`/`WeakRef`, typed arrays, `Atomics`, `Promise`, `BigInt`, `queueMicrotask`, `atob`/`btoa`,
`performance`, ...) and no `Intl`, `TextEncoder`, `URL` or `structuredClone`. The source is patched by
`scripts/quickjs-cproc.patch` (applied to the throwaway checkout, for both back ends) at four spots that cproc cannot
compile; where the change would cost gcc something it is selected with `__CPROC__`, which the qbe back end defines:
- `return js_free_cstring(...);` in `void` functions (a GNU/C++ form; cproc: `expected ';' after 'return' statement`): the
  `return` is dropped.
- `__attribute((unused))` (QuickJS's spelling without the trailing underscores, which cproc does not know): `__maybe_unused`.
- The interpreter loop's computed goto (`&&label`, `goto *`): with `__CPROC__` QuickJS's own `switch` dispatch
  (`DIRECT_DISPATCH` 0), as for mruby (`realworld.md`); the gcc back end keeps computed goto.
- `<stdatomic.h>` and `_Atomic` (the JavaScript `Atomics` object; cproc: `_Atomic type qualifier is not yet supported`): with
  `__CPROC__`, `quickjs-c-atomics.h` maps the C11 operations to libatomic's sized functions (`__atomic_fetch_add_4`, ...), chosen
  with `_Generic` by the size of the element; `qbe-prep.rb` declares them and the qbe link has `-latomic` already (`nm`: 36
  libatomic symbols in the qbe archive, none in the gcc one). The gcc back end inlines `<stdatomic.h>` as before.

QuickJS is built **without `-D_GNU_SOURCE`**, which its CMakeLists defines but its sources do not need on Linux. With the macro,
glibc's `<stdlib.h>` and `<math.h>` declare functions of the types `_Float32x` and `_Float64x` (`strtof32x`, `acosf32x`, ...);
`qbe-prep.rb` drops the typedefs of those two names (it maps `_Float32` and `_Float64`), and cproc stops with `declaration has
no type specifier` on the first of them, in every file that includes either header. This is why every QuickJS file failed at
once on the qbe back end with the flag. Checked by hand with a three-line C file (`#define _GNU_SOURCE`, `#include <stdlib.h>`):
qbe fails, gcc and qbe without the define compile it (`docs/README.md`, "cproc / qbe backend, other").

The qbe build of the engine itself was checked by hand, not by `tests/poly/run.sh`: a small C driver of about 100 lines (`JS_Eval`, the job loop,
a `gc()` function) built with each back end ran those of QuickJS's own `tests/` that need no `quickjs-libc` module, 53 files:
`test_language.js`, `test_closure.js`, `test_loop.js`, `test_builtin.js` (about 1400 lines, as a module), and the regression files
that import only `assert.js` (run as scripts, or as modules where they need strict mode or top-level `await`). 52 pass, the same
files on both back ends; the 53rd, `destructured-export.js`, imports itself as a module and needs the module loader. The test262
suite and the tests that import `qjs:std` or `qjs:os` were not run.

**Python: the system CPython.** Python reports errors through return values, never by unwinding, so nothing needs building:
`Python.h` compiles under EDG as it is, and the backend links `python3-config --ldflags --embed` (Python 3.12 here; the
backend uses `PyErr_GetRaisedException` from 3.12 and `PyErr_Fetch` before). One interpreter per process, started on first use
and never finalized; each `Context` gets its own globals (a `dict` subclass). The uop tinygrad back end (`lib/uop/nfcuop_tinygrad.cpp`) uses
the same rule: it loads the libpython of its executable with `dlopen` and reuses the interpreter if one is started, and it refuses a second
libpython in the process (see `docs/notes/uop.md`).

**ast: the nfcast engine.** `lib/ast` is an interpreter for a Lua 5.4 subset written in C++ (`ast.md`: self-specializing AST
nodes, its own collector, Lua's error messages), so a script error is a C++ exception natively and nothing needs to be built or
patched: the backend links the six `nfcast_*.cpp` files. It exists for what a bytecode VM cannot offer: nodes that specialize
on the types they see, host-object members cached per class, and a tree that later steps can lower to compiled code.

**Go: yaegi in a cgo shared library.** Go has no C++-exception-compatible runtime to rebuild, so the interpreter stays what it is, Go
code, and the host reaches it through a plain C API. `lib/poly/go` is a Go module (the bridge, and yaegi v0.16.1, a Go interpreter
written in Go, pinned by `go.mod` and `go.sum`); `scripts/setup-poly-go.sh` builds it with `go build -buildmode=c-shared` into
`build/poly-go/libnfcgo.so` (about 30 MB; about 50 s on a cold build cache here, a few seconds when only the bridge changed) and
checks that the hand-written `lib/poly/go/nfcgo.h` declares exactly the functions the library exports (`nfcgo_set_host`,
`nfcgo_open`, `nfcgo_close`, `nfcgo_do`). One library serves both back ends: the host, compiled by nfcxx on qbe or gcc, links
`-Lbuild/poly-go -lnfcgo -Wl,-rpath,<that directory>` and only calls into it (a C++ `throw` and `catch` with RAII still work with the
Go runtime loaded, `tests/poly/host.cpp`). It needs Go >= 1.24 (weak pointers make the collector exact), a C compiler for cgo and,
for the first build, the Go module proxy; without any of them `setup-poly-go.sh` exits with status 3 and `tests/poly/run.sh` prints a
`SKIP` line (checked by hand for each case, not part of the suite). The Go runtime starts when the library is loaded: a process that
links the backend has 2 threads and 9 MB resident at the start of `main`, and 7 threads and 29 MB after the first Go context
(measured with a scratch program, not tested).

A script gets a whitelist of standard packages, imported before the first script runs: `bufio bytes container/heap container/list
context encoding/base64 encoding/hex encoding/json errors fmt io math math/bits math/rand path regexp sort strconv strings sync
sync/atomic time unicode unicode/utf8`, yaegi's own source versions of `cmp`, `maps` and `slices`, and the package `nfc` of the
bridge. Not the whole `stdlib.Symbols`: there is no `os`, `net`, `os/exec`, `syscall`, `unsafe`, `reflect`, `runtime` or `plugin`
(importing one is a `SyntaxError` that says the package is not available), and `time.LoadLocation` (it reads files) is removed. A script
gets no files and no processes unless the host binds them. `fmt.Print*` and `println` write to the process's standard output, as
`print` does in Lua and Python; `fmt.Scan*` read an empty input (yaegi points them at the interpreter's own stdin, which is empty), so
the script cannot read the host's.

## Exceptions

Every backend keeps the same three rules (`nfcpoly_lang.hpp`):

1. **C++ calling an interpreter** checks for failure and converts it: `nfcpoly::ScriptError` (`class_name()`, `message()`,
   `backtrace()`), or `SyntaxError` for a parse failure. Never a raw interpreter exception in host code.
2. **An interpreter calling C++** goes through one trampoline per bound function or method. Whatever the C++ code throws is
   caught there and raised in the script instead: a conversion failure is a `TypeError`, a wrong argument count an
   `ArgumentError` (a `TypeError` in Python and JavaScript), a `ScriptError` coming from a nested `Value::call` raises that very script error
   object again, and anything else is an `NfcPoly::HostError` carrying the C++ exception in a `std::exception_ptr`.
3. **A script error unwinds C++ frames properly** where the interpreter's errors are C++ exceptions (Ruby, Lua, ast): the destructors of
   a bound function's locals run when a script it called back into raises (`tests/poly/host.cpp`, `with_guard_raw`). The trampoline
   lets the interpreter's own throw pass (`catch (void*)`: mruby throws an `mrb_jmpbuf*`, Lua a pointer to its private
   `lua_longjmp`; the ast engine throws `nfcast::Thrown`, caught by name and rethrown). Python and JavaScript need no such care: their
   errors are return values, and a C++ frame is unwound by the `ScriptError` that `Value::call` throws.

**Go keeps the rules under a harder constraint.** The Go runtime's frames sit between the host and the bound function (the
host calls `nfcgo_do`, Go runs the script, Go calls `host_cb`, C++ runs the `Callable`), and EDG's exceptions unwind with
`longjmp`: a C++ exception that left `host_cb` would jump over Go frames and leave the Go runtime inconsistent. So `host_cb` catches
everything (`host_dispatch` has the handlers by kind, and `host_cb` a last `catch (...)`) and returns a status; the Go side raises
a Go panic from it (a conversion failure `*nfc.Error{Class: "TypeError"}`, a host exception `*nfc.HostError`, a script error from a
nested `Value::call` the very panic value again). Where `eval` / `Value::call` returns, an unrecovered panic is a `ScriptError`, a
compile error a `SyntaxError`, and a panic that carries a host exception is rethrown as that exception (the `std::exception_ptr` stays
in the host, keyed by a number the `HostError` carries). Removing the handlers of `host_cb` makes the host test end in the
`uncaught exception` handler of `main` with the Go thread still inside its cgo call (mutation check below).

At the host boundary the identity round-trips: a `HostError` that no script code rescued is rethrown by `eval` / `Value::call`
as the original C++ exception, same type and payload (`HostFail` with a code, an `int`); script `ensure`/`finally` blocks (Go:
deferred functions) run on the way. In JavaScript the identity covers whatever was thrown: the value that went through
`Value::execute` and a bound function is thrown again as itself (`e === obj`), be it an `Error`, a string or a plain object
(`tests/poly/host.cpp`, "js only").

| | script error is | host exception inside a script is | `class_name()` of a script error |
| --- | --- | --- | --- |
| Ruby | a Ruby exception | `NfcPoly::HostError < RuntimeError` | the Ruby class (`ArgumentError`) |
| Lua | any value; the backend raises tables `{class, message}` with a `__tostring` | such a table, with a hidden `host` userdata | `LuaError` for `error("text")` |
| Python | a Python exception | `HostError(RuntimeError)`, capsule in `_host` | the Python class (`ValueError`) |
| ast | any value, as in Lua; the backend raises the same `{class, message}` tables | such a table, with a hidden `host` object | `LuaError` for `error("text")` |
| JavaScript | any value; an `Error` carries `name`, `message`, `stack` | `NfcPoly::HostError extends Error`, the `std::exception_ptr` in a property that only C code can name (a private symbol) | its `name` (`TypeError`), or the constructor's name for an `Error` subclass that keeps the name `"Error"`; a thrown value that is not an error (`throw "x"`) is `Error` with `String(value)` as the message |
| Go | a panic with any value | a panic with `*nfc.HostError` (an `error`; `recover()` gives it back as such) | `panic` for a value that is not an error, the Go type of an `error` (`errors.errorString`, `fmt.wrapError`), `runtime.Error`, the `Class` of an `*nfc.Error` (`TypeError`, `ArgumentError`, `GoroutineError`, `ReadOnlyError`) |

A source that does not parse is a `nfcpoly::SyntaxError`, in JavaScript too (QuickJS is asked to compile first and run second, so
that a `SyntaxError` the script throws itself, `new Function('1 +')` or a redeclared `let`, is a `ScriptError` of class
`SyntaxError`).

What the C++ exceptions of mruby buy, measured with `tests/poly/host.cpp` on the gcc back end: the same checks against mruby in
its default setjmp/longjmp mode (a scratch build without `enable_cxx_exception`) fail exactly the destructor checks (the `Guard`
of a bound function is not destroyed when a script raise passes through its frame) and the process then aborts with `double free
or corruption`: `longjmp` over frames that EDG registered on its try stack.

## Values and language idioms

| C++ | script | notes |
| --- | --- | --- |
| `bool`; integer types; `float`, `double` | boolean; integer; float (Go: `bool`, `int` or `uint`, `float64`) | integers are range checked (`ConversionError`; a `TypeError` in a script); a float parameter accepts an integer, an integer parameter a whole float (`5.0`); no implicit truthiness |
| `std::string`, `std::string_view`, `const char*` | string | byte strings (Python: UTF-8 text, other bytes become `bytes`; JavaScript: UTF-8 text, other bytes become a `Uint8Array`, and a string with a lone surrogate stays in JavaScript, where `as<std::string>()` throws `ConversionError`); a view or `const char*` is for parameters (valid during the call); as a result it is refused at compile time |
| `std::vector<T>`, `std::optional<T>` | Array / table / list; nil / None / null | copies; a Lua table is an array when its keys are exactly 1..n (`{}` is one), a Python tuple is one too, a JavaScript `Array` is one (typed arrays and array-likes are not; more than 2^24 elements refuse the copy) |
| `Value` | any | rooted until destroyed; `as<T>()`, `call(name, args...)`, `execute(args...)`, `inspect()`, `class_name()` |
| registered class `T` | an object of the script class | `T&`, `const T&`, `T*` (nil is nullptr) share the object; `T` by value copies it in, and as a result is a new object the script owns |

`def_class<T>(name)` returns a `ClassBuilder` with `ctor<Args...>()`, `method(name, &T::f)`, `method_fn(name, f)` (the first
parameter is the object), `field(name, &T::m)` (reader, and writer unless const). Class-typed members and `T&` results are
shared with their owner; other members are copied. `bind(name, obj)` of a class object gives every language that object (the
same wrapper on every read); `set(name, value)` gives a copy; `bind_fn(name, f)` a function, exact arity. Names of globals are
lower-case identifiers.

| | `eval` returns | state between evals | class use | bound variable `counter` |
| --- | --- | --- | --- | --- |
| Ruby | the last expression | top-level locals, methods, globals | `Vec3.new(1, 2, 3)`, `v.len2`, `v.x = 4` | `counter`, and `self.counter = 5` |
| Lua | the chunk's `return` value; a single expression is returned as is (tried as `return <code>` first) | globals (not `local`s) | `Vec3.new(1, 2, 3)` or `Vec3(1, 2, 3)`, `v:len2()`, `v.x = 4` | `counter`, and `counter = 5` (the globals' metatable) |
| ast | as Lua | globals (not `local`s) | as Lua: `Vec3.new(1, 2, 3)` or `Vec3(1, 2, 3)`, `v:len2()`, `v.x = 4` | as Lua (the globals' metatable) |
| Python | the last expression statement (the source is split with `ast`) | the globals | `Vec3(1, 2, 3)`, `v.len2()`, `v.x = 4` | `counter`, and `counter = 5` at the top level (a `dict` subclass; reads work in functions too; a write through `global counter` does not reach the host and shadows the live variable from then on, so assign at the top level or with `set`) |
| JavaScript | the completion value of the script (a single expression gives its value; an object literal needs parentheses, `({a: 1})`, since `{` starts a block) | globals, `var`, functions; `let`, `const` and `class` of the global lexical scope persist too (declaring one again is a `SyntaxError` the script throws) | `new Vec3(1, 2, 3)` (without `new`: `TypeError`), `v.len2()`, `v.x = 4`; `class P extends Vec3` works | `counter`, and `counter = 5` (an accessor property of the global object; a `let counter` shadows it, and a variable without a setter throws a `TypeError` when assigned) |
| Go | the value of the last top-level statement when it is an expression (the source is cut into its top-level statements; that one is evaluated as `nfc.Ret(expr)`); a statement, a declaration or a call without a result gives nil, several results give the first | package-level declarations, and `var` / `:=` at the top level | `NewVec3(1, 2, 3)`, `v.Len2()`, `v.X()`, `v.SetX(4)` (exported Go names) | `counter`, and `counter = 5`: a Go variable that is synchronized with the host at the boundaries (see "What is live") |

Several languages in one `Context`: every declaration is visible in all of them, and one host object is the same C++ object in
each (`tests/poly/host.cpp`, "cross"). A script array declared with `set` is copied into plain data and visible everywhere; a
script value that is not plain data (a function, a table with keys) stays in its own language, and passing one into another
language (`Value::call` argument) throws `ConversionError`.

**JavaScript specifics** (`tests/poly/host.cpp`, "js only"). JavaScript has one number type, so a rule decides what the host
sees: a number is an integer when it is whole, within the safe integer range (|n| <= 2^53 - 1) and not `-0`; a BigInt is an
integer when it fits 64 bits (a larger one stays in JavaScript, `class_name()` `bigint`). A host integer goes in as a number when
it is a safe integer and as a BigInt otherwise, so a `long long` survives the round trip (and `big + 1` is JavaScript's usual
`TypeError` for mixing BigInt and Number). `NaN`, the infinities, `-0` and fractions are floats; a whole float still converts to an
integer type (`eval<long long>("2 ** 60")`), a fraction or an infinity throws `ConversionError`. `undefined` and `null` are both
nil, and nil goes in as `null` (so does the result of a bound `void` function). A bound class is a JavaScript class: its
constructor must be called with `new` (`TypeError` otherwise), methods and fields (accessors, read-only without a setter) are on
the prototype, so `Object.keys(v)` is empty and `JSON.stringify(v)` is `{}`, `String(v)` is `<Vec3 object>`, and a JavaScript
`class P extends Vec3` is accepted wherever a `Vec3` is. `inspect()` is `JSON.stringify` for arrays, objects and strings and
`String(v)` for the rest.

Promises: QuickJS queues the jobs of promises and runs them only when asked, so nfcpoly runs them when the outermost `eval` or
`Value::call` returns (an `async` function has finished its `await`s of resolved promises by then), not inside a call that a bound
function makes. A job that throws is an error of the call that ran it (the first one, after every job has run); unhandled
rejections are ignored. Top-level `await` and `import` are `SyntaxError`s (an `async` function does the same job; there is no
module loader).

## Optional arguments, computed properties and operators

Three additions for `lib/uop/nfcuop_poly.cpp` (`uop-poly.md`); a binding that does not use them behaves as before
(`tests/poly/host.cpp` is unchanged and passes; `tests/poly/ops.cpp` covers the additions in every language).

- **Optional trailing arguments**: `method_fn(name, f, min_args)` and `bind_fn(name, f, min_args)` let a script pass `min_args` to the
  full count; the missing ones arrive as nil, so those parameters are `Value` or `std::optional<T>`. `Callable::min_arity()` is the
  hook (equal to `arity()` unless asked), the backends check `min_arity() <= given <= arity()` and pad (`arity_fits`, `arity_message`,
  `arity_pad` in `nfcpoly_lang.hpp`), the error text is `wrong number of arguments (given 1, expected 2..3)`. In Go, which is typed,
  the generated function is variadic in the optional parameters (`func (v *Tensor) Sum(o ...any)`, `Index(a0 any, o ...any)`) and pads
  with nil itself; they must be `Value` parameters (`any`). JavaScript's `length` of the function is `min_arity()`.
- **Computed properties**: `property_fn(name, getter)` and `property_fn(name, getter, setter)` on a `ClassBuilder`: `obj.name` calls
  `getter(obj)`, `obj.name = v` calls `setter(obj, v)`; an accessor in JavaScript and Python, `name` / `name=` in Ruby, `__index` in
  Lua, `Name()` / `SetName(v)` in Go. `field()` stays for data members.
- **Operator methods**: a class that registers methods under Python's special method names gets the operators of the language.

  | methods | Python | Ruby | Lua | JavaScript, Go, ast |
  | --- | --- | --- | --- | --- |
  | `__add__ __sub__ __mul__ __truediv__ __mod__ __and__ __or__ __xor__`, `__neg__` | number slots (`+ - * / % & \| ^`, `-x`) | methods `+ - * / % & \| ^ -@` | metamethods `__add __sub __mul __div __mod __band __bor __bxor __unm` | none |
  | `__floordiv__`, `__matmul__`, `__abs__` | `//`, `@`, `abs()` | none | `__idiv` (`//`) | none |
  | `__radd__ ...` (the same names with `r`) | `x OP obj` for a left operand that returns NotImplemented | none (Integer does not ask the other operand) | `x OP obj` | none |
  | `__lt__ __le__ __gt__ __ge__ __eq__ __ne__` | rich comparison; a class without them compares by identity and stays hashable | methods `< <= > >= == !=` | none (Lua makes the result a boolean) | none |
  | `__getitem__` | `obj[k]` (a tuple key arrives as one list) | `obj[k, ...]` | none | none |
  | `__str__`, `__repr__` | `str()`, `repr()` | `to_s`, `inspect` | `__tostring` (`__str__`) | none |

  A method keeps its dunder name in every language too (a script can call `obj.__add__(1)`), except in Go, which skips the names that
  start with `__` (their Go names would collide with `Add`, `Sub`, ...). Python's `==` on the same object still calls the method; in Ruby
  mruby's `==` shortcut answers `true` for the same object without a call.
- **Go: host objects in variables as a `Value`**: yaegi stores a value of an interpreted type that is converted to an interface in a
  box (`interp.valueInterface`), which the bridge took for a Go value to keep as a handle; `encodeDyn` now unwraps the box (a copy of the
  struct and its unexported field, read through its address) so a `*Tensor` held in a variable reaches a `Value` parameter as the
  host object. (`echo(pos)` in the tests used to round-trip as a handle, which hid it.)

## Go: the typed binding model

Go is the one language here with static types, and `Callable` does not know a bound function's parameter and result types. Two
ways out were considered. A *generic dynamic bridge* would bind every host function as `func(...any) any`: `twice_c(21) + 1` is then
a compile error (`any + int`), a class cannot have methods (Go cannot add methods to a type at run time; `reflect.StructOf` makes no
methods), and `v.Len2()` could only be `v.Call("len2")`. The other way, chosen, is to **describe the C++ types**: `make_callable`
computes a `Sig` (parameter and result `TypeDesc`s: bool, signed or unsigned integer, floating, string, `Value`, registered class,
`vector<T>`, `optional<T>`) from the template parameters, backwards compatibly (a new virtual `Callable::signature`, which the other
backends ignore), and the Go backend writes the script-side function down in Go and has yaegi define it as source. A bound function
`twice_c` becomes `func twice_c(a0 int) int { return nfc.Call(7, a0).(int) }`, where `nfc.Call` is the one compiled function that
crosses into C++. A registered class becomes a struct type holding a `*nfc.Obj` (the C++ object, by an id) with typed methods:

```go
type Vec3 struct{ H *nfc.Obj }                       // generated for ctx.def_class<Vec3>("Vec3")
func NewVec3(a0 float64, a1 float64, a2 float64) *Vec3 { ... }            // .ctor<double, double, double>()
func (v *Vec3) X() float64 { ... }                   // .field("x", &Vec3::x): X() and SetX(a0 float64)
func (v *Vec3) Len2() float64 { ... }                // .method("len2", ...): the Go name is the CamelCase of the C++ name (to_s -> ToS)
func (v *Vec3) Dot(a0 *Vec3) float64 { ... }         // a registered class is *Name, in parameters, results, slices and pointers
```

| C++ | Go | notes |
| --- | --- | --- |
| `bool` | `bool` | |
| signed integer types, unsigned integer types | `int`, `uint` | one Go type each, whatever the C++ width; the host range checks (`twice_c(1 << 40)` panics with a `TypeError`) |
| `float`, `double` | `float64` | |
| `std::string`, `std::string_view`, `const char*` | `string` | bytes, not text |
| `std::vector<T>` | `[]T` | copied; a vector of a class is `[]*Name` |
| `std::optional<T>` | `*T` (nil for none) | the optional of a class is the class's `*Name`, nil for none; a script's `*int` result reads in C++ as the number, `nil` as nil |
| `Value` | `any` | a script function, a map, a wrapper: anything; a result that is a host object comes back as a wrapper (`echo(pos).(*Name)`) |
| registered class `T` | `*Name` | `T&`, `const T&`, `T*` (nil is nullptr) share the C++ object; `T` by value copies it in, and as a result is a new object the script owns |

Because the types are known, a wrong call is a **compile error** (`twice_c(1, 2)`, `twice_c("a")`, `vadd(1, 2)`): a `SyntaxError`,
where the other languages raise a `TypeError` or `ArgumentError` at run time. All errors yaegi finds while compiling a snippet,
undefined names and type mismatches included, are `SyntaxError`; only a panic is a `ScriptError`. A host function that is bound
before the class it mentions is registered is defined together with the class when the interpreter starts; when the interpreter
is running already, the class counts as unknown and the parameter is an `any` (a call that really passes such an object still
works, it is checked by the host), and a class that is never registered is an `any` too (the usual "not registered" error comes at
the call). A class without `ctor` still gets `NewName(args ...any)`, which panics with a `TypeError` like the other languages'
`Name.new`. A Go keyword or a name that is not a Go identifier is refused when the declaration is made, with the generated source
in the message. `Value::call(name, ...)` on a host object (`Value pv`) takes the Go names too (`pv.call("Len2")`, `pv.call("SetX", 11.0)`).

A host object stays the same C++ object. Every time an object crosses into Go, the host keeps one reference to it in a table (an
`Owned` count, as in the other backends) and Go gets a new wrapper whose collection releases that reference; a `T&` result is a new
wrapper of the same object each time (`self_ref() != self_ref()`, both change the same C++ object), and `bind` makes one wrapper
that is the variable.

### What is live

A bound variable (`ctx.bind("counter", n)`) has no Go syntax, so it is an ordinary Go package variable of the script (`int`, `uint`,
`float64`, `bool` or `string`), and the backend moves values at the boundaries:

- Before every `eval` and `Value::call` the host's value is copied into the Go variable, and after every host function the script
  calls, since that function may have changed it.
- The script's value is copied back, when it differs from the last copy, before every host function the script calls and when the
  evaluation or call ends.

So a host function sees the script's writes, and the host sees them when `eval` returns; the script sees a change the host made
in between (another thread, a callback) only at the next boundary; a variable written by a goroutine of the script is not
synchronized (it races with the boundaries). A bound `const` variable is read-only: a write is noticed at the next boundary, raises a
`ScriptError` of class `ReadOnlyError`, and the Go variable is reset to the host's value at the boundary after. Tested:
`tests/poly/host.cpp`, "bound variables" (shared and Go-only). The shared tests read `counter` and assign `counter = 100` as they do in
the other languages; what differs is the model, not the syntax.

### The source

yaegi's REPL takes either declarations (when the text starts with `func`, `type`, `var`, `const` or `import`) or statements, not a
mix, does not say what the last statement's value is (a call without a result leaves a stale value), and wraps a statement that
starts with `func` in a function `main` that it then runs again after every later evaluation. So the backend cuts a source into
its top-level statements (`go/scanner`), evaluates declarations together and the statements before the last together, and the last
one, when it is an expression, as `nfc.Ret(expr)` (a call without a result does not compile there and runs plainly, giving nil).
Statements that define nothing, and the `nfc.Ret(expr)` of the last expression, run inside a function that the backend
defines and calls (`func nfc_run() { ... }`, then `nfc_run()`; the name is reserved): their temporaries then live in a frame that is
dropped afterwards. At yaegi's top level every call with arguments takes a slot of its global frame for good, which keeps the
host objects alive and makes each evaluation copy a bigger frame (12000 evaluations of `1 + 1` took 2.0 s that way and 0.7 s in
the function; a function literal called on the spot is no better than the top level, yaegi copies its frame for it). Statements
that define a variable (`x := 1`) run at the top level, where the variable has to live. A declaration of `func main` is refused
(yaegi would run it again after every later evaluation), and so is a `package` clause. `import "strings"` of a package already in
force is accepted and dropped, any other import of a package outside the whitelist is a `SyntaxError` that says so (yaegi also
has `SourcecodeFilesystem` set to an empty file system, so an import cannot load source from the host's disk).

### Threads and goroutines

A script's goroutines run on threads of the Go runtime. Host code runs only on the thread that entered the interpreter: `nfc.Call`
compares its thread (`gettid`) with the one that called `nfcgo_do` and panics with `*nfc.Error{Class: "GoroutineError"}` otherwise,
before anything is sent, and `host_cb` checks `pthread_self()` against the thread marked as inside the interpreter before it
touches any host state, and answers with a status (two independent checks; the mutation checks show each alone suffices and
that removing both makes the goroutine test fail). That also covers a goroutine that outlives the evaluation (the host is not
inside the interpreter then). A goroutine that recovers the panic gets a clean error. **A panic that nothing in the goroutine
recovers ends the process, unless the bridge guards the `go` statement that started the goroutine** (below). Go's rule applies to
the goroutines the bridge does not guard, for a `GoroutineError` as for a nil pointer or an index out of range. Tested in child
processes of the host binary (`go_child` and `go_child_status` in `tests/poly/host.cpp`): the child that starts
`time.AfterFunc(0, func() { panic(...) })` dies (status 2, or SIGABRT: a c-shared Go runtime aborts), and the children that do
the same through a `go` statement of the script (a function literal, a named function with arguments, a method value, a
variadic call, a `go` inside a goroutine) and through `nfc.Go` run on.

**The bare `go` statement is guarded by rewriting its callee** (`lib/poly/go/gostmt.go`). yaegi (v0.16.1, and its master of
February 2026 reads the same) has no hook for it: `interp.Options` has none for goroutines (GoPath, BuildTags, the three streams,
Args, Env, SourcecodeFilesystem, Unrestricted), and a `go` statement is `go runCfg(...)` (an interpreted function) or
`go callFn(...)` (a function value) in `interp/run.go`; `runCfg`'s deferred function prints the panic and panics again. Go has no
process-wide way to survive an unrecovered goroutine panic (`runtime/debug.SetPanicOnFault`, `SetCrashOutput` and signal handlers
only change what is written before the process ends). So the bridge changes the source where the AST says exactly what to change,
as `recover()` is rewritten: the callee of each `go CALL` is wrapped at its byte offsets, `go f(a, b)` becoming
`go nfcGoGuard__(f)(a, b)` (nothing else of the text changes; the line numbers stay). The go statement still evaluates the
function value and the arguments in the calling goroutine, in Go's order (`x := 1; go func(v int) { ... }(x); x = 2` starts with 1).
`nfcGoGuard__` is generic, so the value it gives has the callee's own type and the call checks as before; it calls `nfc.GoGuard`,
which builds that function with `reflect.MakeFunc` and calls the callee, passing the arguments on (a variadic callee gets its slice
through `CallSlice`). A panic of the call is printed on stderr (`panic in a goroutine of the script, contained by its go statement`)
and the goroutine ends with zero results, the process goes on. Covered: a `go` statement whose call has a function value as callee,
so `go f(x)`, `go func() { ... }()`, `go obj.m(x)`, `go pkg.F(x)`, a method expression, a variadic call, and a `go` inside a
goroutine (tests: the child processes of `go_child_status` exit 0; the in-process checks pin the evaluation at the statement, the
types and the results).
- Refused with a `SyntaxError`, before the statement runs: a builtin as the callee (`go close(c)`, `go panic(x)`, `go println(x)`,
  `go copy(a, b)`, ...) and a type written as the callee. The message says to write `go func() { close(c) }()`, which is guarded.
  The check looks at the text of one evaluation: a builtin name that an earlier snippet redeclared is refused too. A refusal stops at its
  statement: the statements before it in the same evaluation have run, as in yaegi's REPL.
- Not covered, and still bare: `time.AfterFunc` and `context.AfterFunc` (both in the whitelist, and both start their function in a
  goroutine of the runtime, not with a `go` statement): a panic in that function ends the process (`go_child_status("afterfunc")`
  pins it; `context.AfterFunc` is the same mechanism and has no test of its own). Any goroutine started by host code outside a
  script's `go` statement. A nil function value: the call panics in the goroutine and is reported, where Go stops the process with a
  fatal error. The names `nfcGoGuard__` and `nfc` are not reserved: a script that declares them breaks the rewrite. Text that does not
  parse is passed on as it is (yaegi reports the error, and no goroutine starts).
- `nfc.Go(f func()) <-chan error` is unchanged: it starts `f` in a goroutine and gives a channel that receives `nil` when `f`
  returned or an `*nfc.Error` (`Class` and `Msg` as the host would see them) for a panic nothing in `f` recovered, so
  `err := <-nfc.Go(f)` is a guarded join that hands the error back to the script. `go f()` is guarded too, but it reports the panic
  on stderr and does not return it; use `nfc.Go` where the error is needed.

Several `Context`s each have their own interpreter and one thread at a time (`tests/poly/host.cpp` uses one from another thread
than the one that created it).

### Errors, the class name and the backtrace

`ScriptError::class_name()` is `panic` for a value that is not an error (`panic("text")`, `panic(42)`), `runtime.Error` for the
runtime's errors that yaegi reports as such (division by zero, a write to a nil map), the Go type of an `error`
(`errors.errorString`, `fmt.wrapError`), and the `Class` of an `*nfc.Error` raised by the bridge. `message()` is the panic value
printed (`Error()` for an error). `backtrace()` is the Go stack of the interpreter (yaegi's frames, not script lines). Three yaegi
quirks matter to scripts and are covered by tests:
- `recover()` after a script's own `panic(x)` is a `reflect.Value` in yaegi, which defeats `r.(string)` and `r.(error)`. **Fixed in the
  bridge** (`lib/poly/go/recover.go`): every call of the builtin `recover()` in a script is wrapped as `nfc.Unwrap(recover())`
  (`nfc.Unwrap` gives `x` back; `nfc.ErrClass(r)` and `nfc.ErrMessage(r)` classify as the host does), found with `go/parser`
  and inserted at the byte offsets of the call, nothing else of the text changes. Not wrapped: `defer recover()` (the call is not
  made by a deferred function, and Go's `defer recover()` recovers nothing either; `go recover()` is a refused builtin of the go
  rewrite, "Threads and goroutines"), a `recover` that is declared
  in the same text, and everything once the script declared its own top-level `recover`. A text that does not parse is left to
  yaegi's error. The explicit form `nfc.Unwrap(recover())` keeps working.
- A script-defined error type loses its methods when it is panicked with (`panic(&MyErr{3})`): the panic builtin is compiled inside
  yaegi and hands over the bare struct, so the host sees `panic` and `&{3}`; this is not fixable in the bridge, which never sees
  the type. After the `recover()` fix an assertion `r.(*MyErr)` to the script's own type succeeds (the reflect types are identical)
  and its methods work, but `r.(error)` is false. A variable of type `error` keeps its methods: `var e error = &MyErr{3}; panic(e)`
  reaches the host as class `interp._error` (yaegi's wrapper type) with message `myerr`. Both are pinned in the tests.
- The value of `recover()` for a panic raised by the bridge (`*nfc.Error`, `*nfc.HostError`) is the typed value, which a script can
  assert.

### Speed and coverage gaps

Measured here (gcc back end, a shared virtual machine, so +-20% between runs; two runs of a scratch program that is not in the
repository, ranges below):

| | Go | Lua | Python |
| --- | --- | --- | --- |
| 100,000 calls of a bound function from a script loop | 445-510 ms | 90-100 ms | 205-220 ms |
| 100,000 method calls (`pos.Len2()`) | 600-820 ms | 120-135 ms | 235-280 ms |
| a loop of 5,000,000 iterations of `s += i` | 195-205 ms | 24-29 ms | 4.9-5.5 s (a module-level loop over a `dict` subclass) |

A call from Go into the host costs about 5 us: the arguments are encoded by hand, cross cgo (the Go runtime switches to a system
stack and back, twice), are decoded by C++ and the result goes back the same way. yaegi runs the loop itself at about 40 ns an
iteration, 8 times slower than Lua and 25 times faster than that Python loop. Compiling is the other cost: `eval` of a small
source takes 55-70 us (20,000 evaluations of `1 + 1`: 1.1-1.2 s) and leaves about 0.7 kB of live heap behind (yaegi keeps the
compiled function; 28-34 MB of resident memory for 20,000 evaluations, 13 MB of it still there after `go_collect`), against 6 us
for `Value::call` of a function the script defined (20,000 calls: 122 ms, no growth). A host that runs the same script many
times should evaluate it once and call the function. A `Context` with an interpreter starts and closes in 3-5 ms (the first one
in a process 6.5 ms), 100 of them one after the other, each keeping a host object, grew the process by 20 MB, 1 MB after
`go_collect` (`bench` numbers; the leak test in `host.cpp` pins the second).

Gaps found in yaegi v0.16.1 (the version pinned in `go.mod`; master of February 2026 behaves the same in the ones tried: `recover()`
after a script panic, `return <-ch`, the `main` re-run). Each is asserted in `tests/poly/host.cpp`, "yaegi's gaps", or in the Go-only
tests, so a yaegi upgrade that fixes one shows up there:

- `return <-ch` panics (`reflect.Value.Set using unaddressable value`); `x := <-ch; return x` works.
- Range over an integer (`for i := range 3`) and over functions are not supported (`internal error ... nil type`).
- Deferred call arguments alias the variable: `defer func(k int){...}(i)` in a loop sees the last `i` in every call.
- A method called on a nil pointer and a failed type assertion panic with `reflect.ValueError` and `interp.cfgError`, not
  `runtime.Error`; an index out of range panics with a plain string.
- Type arguments are inferred only when they agree (`MapSl([]int{1}, func(i int) string {...})` does not compile, `MapSl[int, string](...)`
  does). Generic functions and types with explicit instantiation work (`SumOf`, `Stack[T]`).
- The generic standard packages are yaegi's own partial sources: `slices.Contains`, `slices.Index` and `cmp.Compare` work, `slices.Sort`
  and `slices.Max` do not compile, `maps.Keys` is missing.
- Methods of a type the script defines are invisible to `reflect`, so `Value::call("Add")` on such a value is a `ScriptError` (a
  function value, a compiled type's method and a host object's method work). Not fixable without forking yaegi: a value that
  crosses into compiled code (which every `Value` does) is the bare reflect value of an unnamed struct type (`struct { N int }`,
  tried with a scratch program: no name, no methods, `NumMethod() == 0`), so the bridge cannot even tell which script type to
  dispatch on; a script-side trampoline would need the static type at compile time. Pinned in the tests.
- A statement that starts with `func` is run again after every evaluation by yaegi's own REPL (worked around, above).
- Not tried: the rest of the language (struct tags, `unsafe`, cgo-free reflection of interpreted types, `select` with timeouts, labels
  beyond `continue`/`break`, channels of channels); only what the tests above use is known to work.

## Lifetime

- Objects bound by reference must outlive their use in scripts, as with `nfceval`. Closing a `Context` finalizes the objects the
  scripts still own.
- A `Value` roots its script value (`mrb_gc_register`, `luaL_ref`, a Python reference, a JavaScript reference count, a Go `any` held by the bridge); `eval` and
  `Value::call` restore the GC arena, so a host loop does not grow it (`tests/poly/host.cpp`: 3000 iterations per language).
- Garbage collection: Ruby `GC.start`, Lua and ast `collectgarbage()`, Python reference counting (`gc.collect()` for cycles) release the
  script-owned C++ objects (`Vec3::live` in the test). JavaScript: reference counting releases an object as soon as nothing
  refers to it, and `JS_RunGC` collects cycles (the test binds it as `js_gc()` with the raw access). Go: a wrapper holds a `*nfc.Obj`; when the Go collector finds it dead (a
  finalizer, and a table of weak pointers that `nfc.GC()` / `go_collect(ctx)` sweep after a full collection) the id is queued, and the host
  drops its reference at the next boundary, on the host thread (the end of the evaluation, or the next callback). With `nfc.GC()` that
  is exact for what Go no longer references (`tests/poly/host.cpp`, "the script's GC", and "host objects and the collector"), so the
  shared test passes without waiting; without it the release happens when Go's collector runs. `nfc.GC()` is held to that: it stops
  the collector from starting another cycle while it works (`debug.SetGCPercent(-1)` and no memory limit, under a mutex; a weak pointer
  is cleared when its span is swept, and `runtime.GC` returns before the sweep is complete if a second cycle began), runs at least two
  full passes (a `sync.Pool` keeps what it holds for one more cycle) and goes on while a pass still finds dead wrappers, at most four.
  `nfc.FinalizersOff(true)` silences the finalizers of the wrappers (a test knob): then only the sweep releases anything, which is how
  the tests check the sweep itself (below). What the interpreter still refers to
  keeps its object alive: the temporaries of a top-level `var x = NewVec3()` or `x := NewVec3()` stay in yaegi's top-level frame
  until a later evaluation reuses the slot (observed, untested), so the code that creates and drops objects belongs in a function, or
  in a statement that declares nothing (those run inside the function `nfc_run`, which is what the tests do).
- QuickJS `assert`s that no object is left when a runtime closes (it is built with asserts on, so a leak is an abort and not a
  silent one). The backend frees every `JSValue` it holds when a Context closes: the handles are orphaned first (`Impl::~Impl`),
  and their values are freed only when the interpreter closes, because freeing a value can run the finalizer of a script-owned
  C++ object whose destructor drops another handle while the list of handles is being walked (tested: a C++ object that holds a
  `Value`; freeing the values at once crashes that test). A `JSValue` that the host got through the raw API (`js_value`) has to be
  freed before the Context is destroyed (untested).
- A closed `Context` gives its Go interpreter (about 1 MB) back: the finalizer of a wrapper names the interpreter by number and
  looks it up in a registry, because a finalizer that referred to the interpreter would make a cycle through the runtime's own
  tables and keep every closed interpreter that held a host object alive for good (found by measuring: 1.2 MB of resident memory per
  context, 60 MB for 50 contexts; `tests/poly/host.cpp`, "host objects and the collector", creates 60 contexts that keep an object and
  checks the process grew by less than 30 MB, and the mutation check below fails it).

## Limitations

None of these is covered by a test unless stated.

- No sandbox and no time limit: a script runs in the host process and can loop forever. Not thread safe: one `Context` per
  thread. Python is one interpreter per process (contexts have separate globals but share modules and `sys`).
- Everything crossing the boundary is copied through the neutral `Var` (strings and arrays twice); this is an embedding API, not
  a fast path.
- Constness is not enforced for scripts; inheritance is not tracked (a `Derived` is not accepted as a `Base`); a wrapper returned
  for `T&` is a new script object on every call. Only a Ruby or a JavaScript script can subclass a bound class.
- A bound function that throws a pointer to a non-const object is taken for the interpreter's own throw and passes through
  (Ruby and Lua; Python and JavaScript make a `HostError` of it).
- Re-entrancy (a bound function that evaluates script code itself) is tested for one level of plain code in each language
  (JavaScript also 40 levels deep); deeper nesting is not. Ruby `Fiber`s are untested; Lua coroutines are tested.
- JavaScript: no sandbox (QuickJS has an interrupt handler and a memory limit; neither is wired), no modules, no timers, no
  `console`, no `Intl`; a script can read the clock (`Date.now()`, `performance`), and `Atomics.wait` is refused (`TypeError`: it
  would hang the host thread; tested). The native stack allowed to a script is QuickJS's 1 MiB, re-measured at each outermost
  call into JavaScript so that the host may call from any depth (the re-measuring is untested); runaway recursion is a
  `RangeError`, not a crash (tested). Arrays longer than 2^24 elements refuse the deep copy (tested). Unhandled promise
  rejections are silent. The `Atomics` operations give the right results for every element size on both back ends (tested); that
  they are atomic between threads is untested (nothing here runs a second thread).
- Path B (`NFCXX_PATH=b`) was not tried. The Python backend needs the development files of CPython and is skipped without them.
- Go (`tests/poly/host.cpp` covers the supported forms; the rest is stated as untested):
  - A panic that nothing in a script's goroutine recovers ends the process when the goroutine is not started by a guarded `go`
    statement: `time.AfterFunc` and `context.AfterFunc` start theirs in the runtime, and a refused builtin `go` is not started
    (`nfc.Go` is the guarded way to start one that reports to the script, "Threads and goroutines"). A host function called from a goroutine panics with
    a `GoroutineError` the goroutine can recover; it is never run.
  - yaegi is an interpreter and its coverage of Go has gaps (the list in "Speed and coverage gaps"); compile errors of every kind
    are `SyntaxError`; script-defined error types lose their methods across a panic (`recover()` itself gives the plain value since the
    bridge wraps it).
  - `Value::call` works on function values, methods of compiled types (`strings.Builder`) and host objects (by their Go names),
    not on methods of types the script defines.
  - Bound variables are synchronized at the boundaries only; a write to a read-only one is noticed at the next boundary; goroutines
    that touch a bound variable race with the synchronization. Integers are `int` and `uint` in Go whatever their C++ width
    (checked by the host at the boundary); `float` is `float64`; strings are bytes.
  - An object passed to `Value::call` that the call rejects (an object where an `int` is wanted) stays in the host's table until the
    `Context` closes (observed in the code, not tested). The temporaries of a top-level `var x = NewVec3()` keep that object alive
    until yaegi reuses the slot (observed, untested).
  - The library is about 30 MB and links the whole of yaegi's stdlib symbol table whatever the whitelist (the whitelist is what the
    interpreter is given, not what is linked); building it needs Go >= 1.24, cgo and, once, the module proxy; the Go runtime starts
    its threads when a program that links the backend starts, and stays for the life of the process. A `Context` closes its
    interpreter, but goroutines it started keep running (and keep its memory) until the process ends (untested).
  - Every `eval` compiles, and yaegi keeps part of what it compiles: about 0.7 kB of heap per evaluation stays (the function that
    wraps the statements), so a host that evaluates millions of small sources in one `Context` grows; define a function once and
    call it (`Value::call`, 6 us). To get that low the backend empties two lists of yaegi v0.16.1 that only its debugger reads
    (`Interpreter.roots` and the `child` list of the package scopes; 12 kB and 6 kB an evaluation otherwise) through `reflect` and
    `unsafe`, because they are unexported: another yaegi version has other fields, and the code then leaves them alone (memory then
    grows by that much; untested for another version). A statement that declares a variable (`x := f()`) runs at yaegi's top level
    and takes slots of its global frame for good, and the frame is copied whenever it grows, so the cost of an evaluation grows
    with the number of declarations made so far (measured in a scratch test, not tested: 12000 evaluations of `x := fmt.Sprint(1)`
    took 5.6 s against 0.7 s for 12000 of `1 + 1`).
  - `fmt.Print*` and `println` write to the process's standard output; a script cannot capture or redirect them from the host side.
  - Under AddressSanitizer the Go-only host is clean on both back ends (`tests/poly/asan-go.sh`); valgrind needs the suppression
    file and is much weaker (below).
- Not done: compile-time embedding of scripts (mruby's `mrbc` bytecode in the executable, as `pathb-ptx-emit --embed` does for GPU
  images), and a general fix for `volatile` in EDG's C on the qbe back end (`qbe-prep.rb` handles it for C inputs only, which is
  why mruby and Lua are patched).
- `setup-poly.sh`, `setup-poly-lua.sh` and `setup-poly-js.sh` fetch mruby, Lua and QuickJS-NG from GitHub at their pins (mruby also
  needs `ruby` + `rake` once), like `setup-mruby.sh` and `run_lua.sh`.

## Checks run

`tests/poly/run.sh` on both back ends with all six languages (the host prints how many checks it ran: 1225; JavaScript alone 321, Go alone 337),
8 repeated runs of each binary, each binary under valgrind (`PYTHONMALLOC=malloc valgrind -q --error-exitcode=9`, no errors
reported), the setjmp control build described above, and mutation checks on scratch copies of the backends: dropping the
interpreter pass-through in the Ruby or Lua trampoline, losing script error identity in Python, or leaking the ownership record in
the Ruby or Lua wrappers each fail the checks written for it. The same for the ast backend: dropping the pass-through of
`nfcast::Thrown` in its trampoline, losing script error identity, and not counting the ownership of a wrapped object each fail (the
engine's own mutation checks are in `ast.md`). For JavaScript (gcc back end; three of them again on qbe): dropping
the identity of a rethrown script error (3 checks fail), not rethrowing the host exception (the test ends on an uncaught
`HostError`), not releasing the ownership record in the class finalizer (46 fail), not freeing the values of orphaned handles
(QuickJS's `assert` in `JS_FreeRuntime` aborts), freeing them at once in `orphan` (crash in the check with a C++ object that holds
a `Value`), running promise jobs inside a nested call or a nested eval (2 and 1 fail), the integer rule for whole doubles (3 fail),
the read-only setter (1 fails, then an uncaught `ConversionError`), and the lone surrogate rule (2 fail) are each noticed; a
trampoline that does not catch `std::exception` makes the C++ exception unwind through QuickJS frames and ends in the same
`assert`. The host with JavaScript only was also run under `valgrind --leak-check=full`: the only losses are the `ClassInfo`
objects that the core never frees on purpose (`nfcpoly.cpp`, `Impl::classes`), none from QuickJS or the backend.

For Go (before it met JavaScript and `ast` in one binary): `tests/poly/run.sh` with ruby, lua, python and go gave 697 checks, the
Ruby/Lua/Python binary (`POLY_LANGS="ruby lua python"`) 409, which is the count before Go was added, so the Go edits of the shared checks
changed nothing for the other three, and the Go-only binary (`POLY_LANGS=go`) 284 at the time (the shared checks written through the `Lg` builders, and `go_tests()`; 318 after the hardening below, and 322 with the two lost-release checks of the collector section, which added 34 and changed no shared check, so the six-language binary went from 1172 to 1206, and to 1210 with those checks). Repeated runs of the built host
binaries (`POLY_OUT=DIR`): 25 of each back end's Go-only binary and 10 of each back end's four-language binary, all passed, on a machine
that was busy with other builds. The Ruby/Lua/Python binary under valgrind (`PYTHONMALLOC=malloc valgrind -q --error-exitcode=9`) on
the final code, once per back end, no errors reported (8 repeated runs per back end on an earlier state of the change). The setjmp
control build described above, and the mutation checks on scratch copies of the Ruby, Lua and Python backends (dropping the interpreter
pass-through in the Ruby or Lua trampoline, losing script error identity in Python, leaking the ownership record in the Ruby or Lua
wrappers: each fails the checks written for it), were done before Go was added and not repeated.

For Go, mutation checks on scratch copies of the backend or of the module (`tests/poly/host.cpp` built with `-DTEST_GO` against the modified
`nfcpoly_go.cpp`, or against a library built from the modified module; gcc back end; `no_catch_host` and the finalizer change also on qbe, same result).
Each row is a change that was made and what the tests then did:

| change | result |
| --- | --- |
| no handlers in `host_cb` and `host_dispatch` | the exception unwinds into Go frames: the host test ends in the `uncaught exception` handler of `main`, return code 2 |
| no handlers in `host_dispatch` only | the last `catch (...)` of `host_cb` keeps the process alive but the exception's class and message are lost: the host-exception checks fail |
| no rethrow of the host exception at the boundary | the exception reaches the host as a `ScriptError`; the test ends in `uncaught exception: HostError`, return code 2 |
| no re-raise of a nested script error (on either side) | the destructor check, `same()` and the two-frame check fail |
| no release of dropped wrappers on the host side | 9 collector checks fail |
| the interpreter's objects are leaked at `Context` close instead of released | the shared "released at close" check fails |
| no push of the live variables to Go | the test ends in an uncaught `ReadOnlyError` |
| no keepalive of a host object while the script holds it | the test ends in an uncaught `TypeError` ("already released") |
| the `reflect.Value` of a recovered panic is not unwrapped | the class and message checks fail |
| the statements run at yaegi's top level, not in `nfc_run` | 7 collector checks fail |
| `func main` is not refused | the "main would run again" check fails |
| the finalizer of a wrapper refers to the interpreter | the closed-`Context` memory check fails (the test is the one that found the leak) |
| the thread check of the Go side removed, or that of the host side removed | nothing fails: either one alone refuses the call (both are kept deliberately) |
| both thread checks removed | the goroutine checks fail |
| no weak-pointer sweep in `nfc.GC()` (`sweepDead` finds the dead wrappers but queues nothing) | **6 checks fail in every run, 200 of 200** (`tests/poly/stress-go.sh`-style loop against the modified library): the "host objects and the collector" scenario runs a second time with `nfc.FinalizersOff(true)`, so only the sweep can release the objects. Before that pass existed this mutation was not deterministic (the finalizer goroutine usually released the objects in time: it passed in the last run and failed 4 of 20 earlier ones), which is the flakiness this row used to record |
| `recover()` is not wrapped in `nfc.Unwrap` (`rewriteRecover` returns the text as it is) | the first `recover().(string)` check fails, and the next one ends the test in an uncaught exception (`reflect: Method on nil interface value`) |
| `nfc.Go` does not recover | the in-process check ends the process with Go's fatal panic (the child-process check of the goroutine test would also fail: it expects the guarded child to run on) |
| the rewrite of `go` statements is disabled (`rewriteGo` returns the text as it is; `lib/poly/go/gostmt.go`) | the child-process checks of the literal, named, method, variadic and nested go statements end with a fatal panic, and the refusal checks of `go close(...)` and `go println(...)` find no SyntaxError (qbe, a private library built from a scratch copy: `POLY_LANGS=go`, the Go suite fails on exactly those checks) |
| `go_collect` runs one pass and no sweep when a second collection began (the old `nfc.GC()`: `debug.FreeOSMemory()`, then the sweep) | passes: not distinguishable by the tests, see "The exact collector" |

### The exact collector

`nfc.GC()` (`go_collect(ctx)`) has to release, before the evaluation that called it returns, every host object whose wrapper the
script dropped. Two things release a wrapper's object: its finalizer (on the runtime's finalizer goroutine, at a time nobody
controls) and the sweep of the weak pointers that `nfc.GC()` makes after a full collection (`sweepDead`, `lib/poly/go/interp.go`).
The sweep is what makes the call exact, and the check of it was flaky because the finalizer usually released everything first: a
copy of the library without the sweep passed the suite in most runs and failed it in 4 of 20 (the old row of the mutation table).

- Cause of the flaky check: the check could not tell the sweep from the finalizers. Fixed by `nfc.FinalizersOff(true)`, a knob that
  makes the finalizers release nothing, and by running the whole collector scenario of `go_tests()` a second time with it on
  (`NFC_GO_REPS=N` repeats each pass N times in one process). With it on, the library without the sweep fails 6 checks in every run
  (200 of 200 runs), and the real library passes.
- The rarer failure of the collector check (`Vec3::live != base` after the last `echo` loop, seen once in about 14,300 in-process
  repetitions with both release paths on) is not reproduced, and its cause is not established. Measured on this change, with
  the echo loop and its `go_collect` repeated in one process (`NFC_GO_ECHO=N`; `NFC_GO_BG=1` adds the allocating script goroutine;
  the 300 and 3000 iterations ran a copy of the host that loops only that check): 300 and 3000 iterations, 0 failures; 1500 with the
  goroutine, so that collections run during the loop, 0 failures; 200 with `GOGC=5` and the goroutine, 0 failures (three longer `GOGC=5` runs were stopped by hand after about five
  minutes each, with no failure line printed, so they are not a completed count). Checked against the Go 1.24
  runtime and yaegi v0.16.1 sources, the mechanisms that would leave a dead wrapper alive, or release it late, do not hold for
  `nfc.GC()`: (a) `runtime.GC` returns before the sweep of its cycle is done only when another cycle began meanwhile
  (`runtime/mgc.go`), and `nfc.GC()` holds the collector off (GC percent -1, no memory limit); a weak handle and the finalizer of the
  same object are handled in the same sweep step (`freeSpecial`, `runtime/mgcsweep.go`), so after `runtime.GC` returns a dead wrapper
  has its weak pointer cleared and its id queued by `sweepDead`, or it is still reachable; (b) `sync.Pool`: `reflect` clears a call
  frame before it puts it back (`reflect/value.go`), and yaegi allocates a frame per call without a pool (`interp/interp.go`); (c) a
  finalizer is queued in the same sweep step that clears its wrapper's weak pointer, so the sweep sees every wrapper a finalizer
  queues. One root was found and is harmless here: the finalizer
  goroutine's `runfinq` passes the object in its register area (`regs`, `runtime/mfinal.go`), so the last object finalized stays in
  memory until the next finalizer runs; its release was queued by the finalizer, so the host object is released. What is left is a
  root that keeps a wrapper reachable through the whole collection, and no source above shows one.
- Two paths that lost release ids were found while checking this (deterministic, and covered by two checks of
  `tests/poly/host.cpp`, "host objects and the collector"): (1) a call whose message writes a read-only variable failed with
  ReadOnlyError, and the host returned before reading the release list that follows the writes, so the host kept those objects;
  (2) a call from a goroutine the script started: the Go side took the release queue into the message, and the host refused the
  message (`hostThread`) without reading it. Fixed: `host_dispatch` reads the whole message before it raises a write error, and
  `writeMeta` returns an undo that puts the releases back and unmarks the variables when the host refuses. Neither path is taken by
  the echo-loop check (it sends no refused message), so they do not explain the rare failure.
- Stress: `tests/poly/stress-go.sh [N]` builds the Go-only host and runs it N times per back end (default 200, `JOBS=4` at a time).
  Result on this change: 200 runs of each back end's binary, 4 at a time: 0 failed on qbe, 0 failed on gcc. The mutation result recorded earlier (the same 200
  runs of the qbe binary against the library without the sweep: 200 failed, 6 checks each) was not repeated for this change.

### Sanitizers and valgrind

AddressSanitizer works with the Go backend, on both back ends, and gives a clean run: `tests/poly/asan-go.sh` builds the Go-only host
with `nfcxx -fsanitize=address` (gcc: gcc's instrumentation of the C that EDG generates; qbe: cproc's checks of every load and store,
`asan.md`) and links the uninstrumented `libnfcgo.so`; it runs all the checks, and LeakSanitizer finds nothing at exit. (CI runs it
after `tests/poly/run.sh`.) What this covers and what it does not:

- What works: libasan is the first library in the process, so its `malloc` is the one `C.malloc` in cgo calls: the replies that Go
  hands to the host are ASan blocks, and a read past one, a write past the buffer the host allocates for a reply, or a reply nobody
  frees is found. The Go runtime does not mind: it starts its threads, installs its signal handlers and runs the whole suite
  with libasan loaded (nothing needed beyond `detect_leaks=1`; that the two coexist was found by trying, not by reading either one).
- What is not instrumented: the Go runtime and yaegi themselves (Go code; a Go build with `-asan` would need the whole library and
  cgo's `-asan` mode, not tried), and EDG's runtime library (`asan.md`, "Limits").
- Not clean without a suppression: nfcpoly's core keeps the table of registered classes for the life of the process on purpose
  (`Impl::classes`, "never freed"), so LeakSanitizer reports 164 allocations (12816 bytes) from `declare_class` and the `ClassBuilder`
  calls that hang off it. `tests/poly/lsan.supp` suppresses `declare_class`; the rest of the report is then empty. All of it
  was from the core: not one block from `GoLang` or the Go library.
- The signal is real (mutated copies of `nfcpoly_go.cpp`): without the `std::free(out)` of the reply in `go()`, LeakSanitizer
  reports 163,259 bytes in 6,587 blocks allocated in cgo's `_Cfunc__Cmalloc` (gcc); with the reply buffer of `host_cb`
  allocated 2 bytes short (`reply.b.size() - 1`), ASan reports a `heap-buffer-overflow` in `memcpy` from `host_dispatch`, on gcc and
  on qbe. The sanitizers are not run on the six-language binary; the Go-only one is the subject.

valgrind is much weaker. The Go runtime switches and copies goroutine stacks, which valgrind's stack-switch heuristics cannot
follow ("client switching stacks?"), and the collector reads memory it has not initialised, so an unfiltered run reports 3,800 to
6,100 errors (two earlier runs) and millions of reports are matched by the file. `tests/poly/valgrind-go.supp` and
`tests/poly/valgrind-go.sh` (by hand, 5-8 minutes per back end; `NFCXX_BACKEND=gcc|qbe`) give a run with a meaningful signal: the
rules drop an error kind (`Cond`, `Value*`, `Addr*`) only when its innermost frame is in `libnfcgo.so`; the `Addr*` errors whose
innermost frame is one of the host's functions that read memory Go owns (`host_cb`, `host_dispatch`, `GoLang::decode`, the `Rd`
reader: every such access to a Go stack or heap block is reported as "invalid ... in a rw- anonymous segment", whatever the code
does); the uses of "uninitialised" bytes that Go wrote, in any stack that passes through the reply parser (`read_meta`, `decode`) or the
two callbacks; the class table of the core; and the thread-local storage of the Go runtime's threads. What is left is a leak
of a block that C or C++ code, or cgo's `C.malloc`, allocated (Go allocates with `mmap`, so a leak report is never Go's), a bad or
mismatched free, and an invalid access by any C++ code that is not one of those functions. It cannot see a read past the end of a
buffer inside the suppressed functions: ASan does. Results: `NFCXX_BACKEND=gcc tests/poly/valgrind-go.sh` and the same with `qbe` run all 322 checks and report
0 errors (3.6 to 5.0 million reports matched by the file). The two mutated copies above are both found: no `free` of the reply gives
`definitely lost: 161,910 bytes in 6,587 blocks` (allocated in `_Cfunc__Cmalloc`, 51 errors, exit 9), and the short reply buffer an
`Invalid write of size 1` in `memmove` from `host_dispatch` (exit 9).


