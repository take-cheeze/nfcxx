# nfcpoly: scripts in other languages, embedded in a C++ program

`lib/poly` lets a program compiled with nfcxx evaluate source text of **Ruby** (mruby), **Lua**, **Python** (CPython),
**JavaScript** (QuickJS-NG) and **ast** (Lua syntax, run by the self-specializing AST interpreter of `lib/ast`, `ast.md`) while it
runs, with host objects and functions visible to the scripts and the scripts' values visible to C++: a small version of
GraalVM's polyglot `Context.eval(language, source)` with shared bindings, several languages in one `Context`. Unlike `nfceval`
(`eval.md`) no compiler runs per snippet.

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

`tests/poly/run.sh` builds all five for `qbe` and `gcc` and runs `tests/poly/host.cpp` (CI: `ci.yml`); Python is skipped
with a `SKIP` line when `python3-config` or `Python.h` is missing. `POLY_LANGS="lua js ast"` selects languages.

Each backend has a header for raw access to its interpreter next to nfcpoly (`nfcpoly_mruby.hpp`, `nfcpoly_lua.hpp`,
`nfcpoly_python.hpp`, `nfcpoly_js.hpp`): the interpreter's state, and a way to get the script value behind a `Value`. For
JavaScript: `js_context(ctx)` (a `JSContext*`), `js_value(v)` (a new `JSValue` reference to free with `JS_FreeValue`) and
`js_wrap(ctx, jsvalue)` (a `Value` for a raw `JSValue`); `tests/poly/host.cpp` uses them to run `JS_RunGC`, to read a promise's
state, to define a native function with `JS_NewCFunction` and to build a `Value` from a `JSValue`.

## Architecture

- `nfcpoly.hpp` (the whole public API, no interpreter header) and `nfcpoly.cpp` are language neutral. C++ values convert to
  and from a neutral `Var` (nil, bool, integer, float, string, array, a registered C++ object, or a handle to a script
  value). `nfcpoly_lang.hpp` is the interface a backend implements: `eval`, `call`, deep conversion of arrays, and the
  declarations (global function, value, live variable, class with methods, properties and constructor).
- A backend converts between `Var` and its interpreter's values, defines what was declared, and registers itself with a
  static `LangRegistrar`. A language's interpreter starts on its first `eval`; everything declared before is replayed into
  it, and later declarations reach the running ones.
- Decoding is shallow (plain data and registered objects convert, everything else becomes a rooted handle); arrays are
  converted when a C++ type asks for one (`std::vector<T>`, `Value::as`), so a script array passed to a `Value` parameter
  keeps its identity.
- Registered C++ objects carry a shared ownership record (`Owned`): the C++ object is deleted when the last script wrapper
  and the last `Var`/`Value` are gone. A handle to a script value is orphaned, not left dangling, when its `Context` goes
  away, so a `Value` outlives its `Context` safely (plain values and co-owned objects keep working; asking the interpreter
  throws `Error`).

## Building the interpreters

All four that need building are checked on both back ends; the `ast` engine is C++ and is compiled with the host.

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
and never finalized; each `Context` gets its own globals (a `dict` subclass).

**ast: the nfcast engine.** `lib/ast` is an interpreter for a Lua 5.4 subset written in C++ (`ast.md`: self-specializing AST
nodes, its own collector, Lua's error messages), so a script error is a C++ exception natively and nothing needs to be built or
patched: the backend links the six `nfcast_*.cpp` files. It exists for what a bytecode VM cannot offer: nodes that specialize
on the types they see, host-object members cached per class, and a tree that later steps can lower to compiled code.

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

At the host boundary the identity round-trips: a `HostError` that no script code rescued is rethrown by `eval` / `Value::call`
as the original C++ exception, same type and payload (`HostFail` with a code, an `int`); script `ensure`/`finally` blocks run on
the way. In JavaScript the identity covers whatever was thrown: the value that went through `Value::execute` and a bound function
is thrown again as itself (`e === obj`), be it an `Error`, a string or a plain object (`tests/poly/host.cpp`, "js only").

| | script error is | host exception inside a script is | `class_name()` of a script error |
| --- | --- | --- | --- |
| Ruby | a Ruby exception | `NfcPoly::HostError < RuntimeError` | the Ruby class (`ArgumentError`) |
| Lua | any value; the backend raises tables `{class, message}` with a `__tostring` | such a table, with a hidden `host` userdata | `LuaError` for `error("text")` |
| Python | a Python exception | `HostError(RuntimeError)`, capsule in `_host` | the Python class (`ValueError`) |
| ast | any value, as in Lua; the backend raises the same `{class, message}` tables | such a table, with a hidden `host` object | `LuaError` for `error("text")` |
| JavaScript | any value; an `Error` carries `name`, `message`, `stack` | `NfcPoly::HostError extends Error`, the `std::exception_ptr` in a property that only C code can name (a private symbol) | its `name` (`TypeError`), or the constructor's name for an `Error` subclass that keeps the name `"Error"`; a thrown value that is not an error (`throw "x"`) is `Error` with `String(value)` as the message |

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
| `bool`; integer types; `float`, `double` | boolean; integer; float | integers are range checked (`ConversionError`; a `TypeError` in a script); a float parameter accepts an integer, an integer parameter a whole float (`5.0`); no implicit truthiness |
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

## Lifetime

- Objects bound by reference must outlive their use in scripts, as with `nfceval`. Closing a `Context` finalizes the objects the
  scripts still own.
- A `Value` roots its script value (`mrb_gc_register`, `luaL_ref`, a Python reference, a JavaScript reference count); `eval` and
  `Value::call` restore the GC arena, so a host loop does not grow it (`tests/poly/host.cpp`: 3000 iterations per language).
- Garbage collection: Ruby `GC.start`, Lua and ast `collectgarbage()`, Python reference counting (`gc.collect()` for cycles) release the
  script-owned C++ objects (`Vec3::live` in the test). JavaScript: reference counting releases an object as soon as nothing
  refers to it, and `JS_RunGC` collects cycles (the test binds it as `js_gc()` with the raw access).
- QuickJS `assert`s that no object is left when a runtime closes (it is built with asserts on, so a leak is an abort and not a
  silent one). The backend frees every `JSValue` it holds when a Context closes: the handles are orphaned first (`Impl::~Impl`),
  and their values are freed only when the interpreter closes, because freeing a value can run the finalizer of a script-owned
  C++ object whose destructor drops another handle while the list of handles is being walked (tested: a C++ object that holds a
  `Value`; freeing the values at once crashes that test). A `JSValue` that the host got through the raw API (`js_value`) has to be
  freed before the Context is destroyed (untested).

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
- Not done: compile-time embedding of scripts (mruby's `mrbc` bytecode in the executable, as `scripts/cuda-embed.rb` does for GPU
  images), and a general fix for `volatile` in EDG's C on the qbe back end (`qbe-prep.rb` handles it for C inputs only, which is
  why mruby and Lua are patched).
- `setup-poly.sh`, `setup-poly-lua.sh` and `setup-poly-js.sh` fetch mruby, Lua and QuickJS-NG from GitHub at their pins (mruby also
  needs `ruby` + `rake` once), like `setup-mruby.sh` and `run_lua.sh`.

## Checks run

`tests/poly/run.sh` on both back ends with all five languages (the host prints how many checks it ran: 884; JavaScript alone 321),
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
