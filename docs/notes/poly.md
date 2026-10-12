# nfcpoly: scripts in other languages, embedded in a C++ program

`lib/poly` lets a program compiled with nfcxx evaluate source text of **Ruby** (mruby), **Lua** and **Python** (CPython)
while it runs, with host objects and functions visible to the scripts and the scripts' values visible to C++: a small
version of GraalVM's polyglot `Context.eval(language, source)` with shared bindings, several languages in one `Context`.
Unlike `nfceval` (`eval.md`) no compiler runs per snippet.

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

`tests/poly/run.sh` builds all three for `qbe` and `gcc` and runs `tests/poly/host.cpp` (CI: `ci.yml`); Python is skipped
with a `SKIP` line when `python3-config` or `Python.h` is missing. `POLY_LANGS="lua"` selects languages.

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

All three are checked on both back ends.

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

**Python: the system CPython.** Python reports errors through return values, never by unwinding, so nothing needs building:
`Python.h` compiles under EDG as it is, and the backend links `python3-config --ldflags --embed` (Python 3.12 here; the
backend uses `PyErr_GetRaisedException` from 3.12 and `PyErr_Fetch` before). One interpreter per process, started on first use
and never finalized; each `Context` gets its own globals (a `dict` subclass).

## Exceptions

Every backend keeps the same three rules (`nfcpoly_lang.hpp`):

1. **C++ calling an interpreter** checks for failure and converts it: `nfcpoly::ScriptError` (`class_name()`, `message()`,
   `backtrace()`), or `SyntaxError` for a parse failure. Never a raw interpreter exception in host code.
2. **An interpreter calling C++** goes through one trampoline per bound function or method. Whatever the C++ code throws is
   caught there and raised in the script instead: a conversion failure is a `TypeError`, a wrong argument count an
   `ArgumentError` (a `TypeError` in Python), a `ScriptError` coming from a nested `Value::call` raises that very script error
   object again, and anything else is an `NfcPoly::HostError` carrying the C++ exception in a `std::exception_ptr`.
3. **A script error unwinds C++ frames properly** where the interpreter's errors are C++ exceptions (Ruby, Lua): the destructors of
   a bound function's locals run when a script it called back into raises (`tests/poly/host.cpp`, `with_guard_raw`). The trampoline
   lets the interpreter's own throw pass (`catch (void*)`: mruby throws an `mrb_jmpbuf*`, Lua a pointer to its private
   `lua_longjmp`). Python needs no such care: its errors are return values, and a C++ frame is unwound by the `ScriptError`
   that `Value::call` throws.

At the host boundary the identity round-trips: a `HostError` that no script code rescued is rethrown by `eval` / `Value::call`
as the original C++ exception, same type and payload (`HostFail` with a code, an `int`); script `ensure`/`finally` blocks run on
the way.

| | script error is | host exception inside a script is | `class_name()` of a script error |
| --- | --- | --- | --- |
| Ruby | a Ruby exception | `NfcPoly::HostError < RuntimeError` | the Ruby class (`ArgumentError`) |
| Lua | any value; the backend raises tables `{class, message}` with a `__tostring` | such a table, with a hidden `host` userdata | `LuaError` for `error("text")` |
| Python | a Python exception | `HostError(RuntimeError)`, capsule in `_host` | the Python class (`ValueError`) |

What the C++ exceptions of mruby buy, measured with `tests/poly/host.cpp` on the gcc back end: the same checks against mruby in
its default setjmp/longjmp mode (a scratch build without `enable_cxx_exception`) fail exactly the destructor checks (the `Guard`
of a bound function is not destroyed when a script raise passes through its frame) and the process then aborts with `double free
or corruption`: `longjmp` over frames that EDG registered on its try stack.

## Values and language idioms

| C++ | script | notes |
| --- | --- | --- |
| `bool`; integer types; `float`, `double` | boolean; integer; float | integers are range checked (`ConversionError`; a `TypeError` in a script); a float parameter accepts an integer, an integer parameter a whole float (`5.0`); no implicit truthiness |
| `std::string`, `std::string_view`, `const char*` | string | byte strings (Python: UTF-8 text, other bytes become `bytes`); a view or `const char*` is for parameters (valid during the call); as a result it is refused at compile time |
| `std::vector<T>`, `std::optional<T>` | Array / table / list; nil / None | copies; a Lua table is an array when its keys are exactly 1..n (`{}` is one), a Python tuple is one too |
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
| Python | the last expression statement (the source is split with `ast`) | the globals | `Vec3(1, 2, 3)`, `v.len2()`, `v.x = 4` | `counter`, and `counter = 5` at the top level (a `dict` subclass; reads work in functions too; a write through `global counter` does not reach the host and shadows the live variable from then on, so assign at the top level or with `set`) |

Several languages in one `Context`: every declaration is visible in all of them, and one host object is the same C++ object in
each (`tests/poly/host.cpp`, "cross"). A script array declared with `set` is copied into plain data and visible everywhere; a
script value that is not plain data (a function, a table with keys) stays in its own language, and passing one into another
language (`Value::call` argument) throws `ConversionError`.

## Lifetime

- Objects bound by reference must outlive their use in scripts, as with `nfceval`. Closing a `Context` finalizes the objects the
  scripts still own.
- A `Value` roots its script value (`mrb_gc_register`, `luaL_ref`, a Python reference); `eval` and `Value::call` restore the GC
  arena, so a host loop does not grow it (`tests/poly/host.cpp`: 3000 iterations per language).
- Garbage collection: Ruby `GC.start`, Lua `collectgarbage()`, Python reference counting (`gc.collect()` for cycles) release the
  script-owned C++ objects (`Vec3::live` in the test).

## Limitations

None of these is covered by a test unless stated.

- No sandbox and no time limit: a script runs in the host process and can loop forever. Not thread safe: one `Context` per
  thread. Python is one interpreter per process (contexts have separate globals but share modules and `sys`).
- Everything crossing the boundary is copied through the neutral `Var` (strings and arrays twice); this is an embedding API, not
  a fast path.
- Constness is not enforced for scripts; inheritance is not tracked (a `Derived` is not accepted as a `Base`); a wrapper returned
  for `T&` is a new script object on every call. Only a Ruby script can subclass a bound class.
- A bound function that throws a pointer to a non-const object is taken for the interpreter's own throw and passes through.
- Re-entrancy (a bound function that evaluates script code itself) is tested for one level of plain code in each language;
  deeper nesting is not. Ruby `Fiber`s are untested; Lua coroutines are tested.
- Path B (`NFCXX_PATH=b`) was not tried. The Python backend needs the development files of CPython and is skipped without them.
- Not done: compile-time embedding of scripts (mruby's `mrbc` bytecode in the executable, as `scripts/cuda-embed.rb` does for GPU
  images), and a general fix for `volatile` in EDG's C on the qbe back end (`qbe-prep.rb` handles it for C inputs only, which is
  why mruby and Lua are patched).
- `setup-poly.sh` and `setup-poly-lua.sh` fetch mruby and Lua from GitHub at their pins (mruby also needs `ruby` + `rake` once),
  like `setup-mruby.sh` and `run_lua.sh`.

## Checks run

`tests/poly/run.sh` on both back ends with all three languages (the host prints how many checks it ran), 8 repeated runs of each
binary, each binary under valgrind (`PYTHONMALLOC=malloc valgrind -q --error-exitcode=9`, no errors reported), the setjmp control
build described above, and mutation checks on scratch copies of the backends: dropping the interpreter pass-through in the Ruby or
Lua trampoline, losing script error identity in Python, or leaking the ownership record in the Ruby or Lua wrappers each fail the
checks written for it.
