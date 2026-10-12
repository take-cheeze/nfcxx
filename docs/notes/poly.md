# nfcpoly: scripts in another language, embedded in a C++ program

`lib/poly/nfcpoly.hpp` + `nfcpoly.cpp` let a program compiled with nfcxx evaluate source text of another language
while it runs, with host objects and functions visible to that code and the script's values visible to C++: a small
version of GraalVM's polyglot `Context.eval(language, source)` with shared bindings. The language is Ruby, run by
mruby 4.0.0 (the pin of `scripts/setup-mruby.sh`) embedded as a library. The `language` argument of `eval` is the
place a second language would plug in; only `"ruby"` (alias `"mruby"`) exists.

What this is not: GraalVM's partial evaluation or a heap shared by languages. Values cross by copy, or as handles to
objects (a script wrapper around a C++ object, or a `Value` rooting a script object), and the C++ side declares what a
script may touch. Unlike `nfceval` (`eval.md`) there is no compiler run per snippet: a script is parsed by mruby.

```cpp
#include "nfcpoly.hpp"
nfcpoly::Context ctx;
ctx.def_class<Vec3>("Vec3").ctor<double, double, double>().field("x", &Vec3::x).method("len2", &Vec3::len2);
Vec3 pos{1, 2, 3};
ctx.bind("pos", pos);                       // `pos` in a script is this very object
ctx.bind_fn("scale", &scale);               // `scale(2.0)` calls the C++ function
int r = ctx.eval<int>("ruby", "pos.x = 4; pos.x * scale(2.0)");   // pos.x is 4 in C++ afterwards
Value v = ctx.eval_value("ruby", "[3, 1, 2]");
std::vector<int> sorted = v.call("sort").as<std::vector<int>>();
```

Build and test: `scripts/setup-poly.sh` (per back end), then
`nfcxx -I lib/poly -I build/poly/<backend>/include host.cpp lib/poly/nfcpoly.cpp build/poly/<backend>/lib/libmruby.a`;
`tests/poly/run.sh` does both for `qbe` and `gcc` (CI: `ci.yml`).

## Building mruby with C++ exceptions

`scripts/setup-poly.sh` builds mruby with its own rake build (`scripts/mruby-rt-config.rb`) into
`build/poly/<backend>/{lib/libmruby.a,include}`: `nfcc` is the C compiler, `nfcxx` the C++ compiler and the linker,
and `conf.enable_cxx_exception` is on. In that mode mruby's `MRB_THROW` is a C++ `throw` of an `mrb_jmpbuf*`,
`MRB_TRY`/`MRB_CATCH` are `try`/`catch`, and mruby compiles `src/vm.c`, `error.c`, `gc.c` (and the compiler gem's
parser and code generator) as C++ through generated `*-cxx.cxx` wrappers; every other file stays C. With nfcxx as the
C++ compiler those throws are EDG's exception runtime (`libC.a`: `__throw`, the try stack), the same one every `throw`
and `catch` in the host uses (checked with `nm` on both back ends: exactly the five `-cxx.o` members of `libmruby.a`, `vm`, `error`, `gc`,
`codegen` and `y.tab`, reference `__throw` and `__curr_eh_stack_entry`; the `_setjmp` they also reference is EDG's own
try stack; no other member references `setjmp` or `longjmp`).

Two things had to be handled:

- **Computed goto.** `vm.c` compiled as C++ by EDG fails on `goto *optable[insn]` (the table is `const void *`;
  `cxx-driver.md`). The config defines `MRB_USE_VM_SWITCH_DISPATCH`.
- **`volatile`.** The three C++ files hold exactly one volatile, `volatile int err` in `mrb_core_init_protect`
  (`src/error.c`), a setjmp guard. cproc rejects the store (`volatile store is not yet supported`, qbe back end;
  README "Known limitations"). With real `try` blocks the guard is redundant (EDG keeps the locals of a try block in
  memory itself, it emits `__suppress_optim_on_vars_in_try` for them), so `scripts/mruby-cxx-novolatile.patch` drops
  the qualifier, applied to the throwaway checkout under `build/poly/src` for both back ends. A `-Dvolatile=` in the
  config was tried first and does not work: it breaks the hosted libstdc++ headers (`std::launder`,
  `numeric_limits<volatile T>`). The general fix would be to let `qbe-prep.rb` treat volatile in EDG's C as it does for
  C inputs (`realworld.md`); not done.

The gems are `scripts/mruby-rt-config.rb`'s list: the compiler (scripts are parsed at run time), sprintf, the `*-ext`
gems, `mruby-set`, `-error`, `-metaprog`, `-math`, `-bigint`, `-struct`, `-toplevel-ext`. No `mruby-io`, `-exit`,
`-time` or `-sleep`: a script has no files, no `exit` and no clock unless the host binds them. No `_Complex` gems
(cproc).

## Exceptions

An exception in mruby is a C++ `throw`, so three rules keep the two worlds consistent (all in `nfcpoly.cpp`):

1. **C++ calling the interpreter** goes through `mrb_protect_error`. A script error becomes `nfcpoly::ScriptError`
   (`class_name()`, `message()`, `backtrace()`; `SyntaxError` for a parse failure), never an `mrb_jmpbuf*` in host code.
2. **The interpreter calling C++** goes through one trampoline per bound function or method. Whatever the C++ code
   throws is caught there and raised in the script instead (a foreign C++ exception passing through the VM would
   leave `mrb->jmp` and the call stack inconsistent): a conversion failure is a `TypeError`, a wrong argument count an
   `ArgumentError`, a `ScriptError` coming from a nested `Value::call` re-raises that very script exception object, and
   anything else is an `NfcPoly::HostError` (a `RuntimeError`) carrying the C++ exception in a `std::exception_ptr`
   (hidden ivar `@__host`). The one type the trampoline lets through is `mrb_jmpbuf*`, a script raise passing through a
   bound function (raw mruby API) on its way to a script handler.
3. **A script raise unwinds C++ frames properly.** The destructors of a bound function's locals run when a script it
   called back into raises (`tests/poly/host.cpp`, `with_guard`).

At the host boundary the identity round-trips: a `HostError` that no script code rescued is rethrown by `eval` /
`Value::call` as the original C++ exception, same type and payload (`HostFail` with a code, an `int`), through
`std::rethrow_exception`; script `ensure` blocks run on the way.

What the C++ build buys, measured with `tests/poly/host.cpp` on the gcc back end: the same checks against mruby in
its default setjmp/longjmp mode (a scratch build with the `enable_cxx_exception` line removed) fail exactly the destructor checks (the `Guard` of a bound function is not
destroyed when a script raise passes through its frame) and the process then aborts with `double free or corruption`:
`longjmp` over frames that EDG registered on its try stack. With `enable_cxx_exception` all pass.

## Values

| C++ | script | notes |
| --- | --- | --- |
| `bool`; integer types; `float`, `double` | `true`/`false`; Integer; Float | integers are range checked (`ConversionError`; `TypeError` in a script); a Float parameter accepts an Integer; no implicit truthiness |
| `std::string`, `const char*` (result) | String | byte strings; `std::string_view` only as a parameter (a view into the script's string); `const char*` parameters and `string_view` results are refused at compile time |
| `std::vector<T>`, `std::optional<T>` | Array; `nil` or T | copies |
| `Value` | any | rooted until destroyed; `as<T>()`, `call(name, args...)`, `inspect()`, `class_name()` |
| registered class `T` (`def_class`) | an instance of the script class | `T&`, `const T&`, `T*` (nil is nullptr) share the object; `T` by value copies it in, and as a result is a new object the script's GC owns |

`def_class<T>(name)` returns a `ClassBuilder` with `ctor<Args...>()`, `method(name, &T::f)`, `method_fn(name, f)` (first
parameter is the object), `field(name, &T::m)` (reader, and `name=` unless const). A script can subclass a bound class.
Class-typed members and `T&` results are shared with their owner (a borrowed wrapper); other members are copied.

`bind(name, obj)` of a class object gives the script that object (the same wrapper on every read); of an arithmetic or
`std::string` variable a live reader, and `self.name = v` writes it back (a plain `name = v` in Ruby is a new local).
`set(name, value)` gives a copy. `bind_fn(name, f)`: a function, function pointer or lambda with one non-template call
operator, exact arity. Names are lower-case identifiers; bound things are methods of `Kernel`.

## Lifetime

- Objects bound by reference must outlive their use in scripts, as with `nfceval`. A `Value` and anything borrowed from
  one must not outlive the `Context`. Closing the interpreter finalizes the objects the script owns.
- `Value` roots its script object (`mrb_gc_register`); `eval` and `Value::call` restore the GC arena, so a host loop of
  evaluations does not grow it (`tests/poly/host.cpp`: 3000 iterations).
- Top-level local variables, methods and constants persist between `eval` calls; a parse error does not lose them.

## Limitations

None of these is covered by a test unless stated.

- No sandbox and no time limit: a script runs in the host process and can loop forever (mruby may offer a
  per-instruction hook; not looked at). Not thread safe: one `Context` per thread.
- Constness is not enforced for scripts (a `const T&` result can be mutated by calling a non-const method); inheritance
  is not tracked (a `Derived` is not accepted as a `Base`); a wrapper returned for `T&` is a new object on every call
  (`a.child.equal?(a.child)` is false).
- `nfcpoly.cpp` includes `<mruby/throw.h>`, which mruby documents as core-internal, to name the type `mrb_jmpbuf` in
  one `catch`; it defines `MRB_USE_CXX_EXCEPTION` for it, so the library must be linked against a libmruby built by
  `setup-poly.sh` (a setjmp build links and runs, but loses the destructor guarantee above, see the control).
- Re-entrancy (a bound function that evaluates script code) works in `tests/poly/host.cpp` for one level of plain code;
  deeper nesting and `Fiber`s are untested.
- Path B (`NFCXX_PATH=b`) was not tried. mruby needs gcc or cproc for its C files and EDG for three C++ ones.
- Not done: a second language, and compile-time embedding of scripts (mruby's `mrbc` bytecode in the executable, as
  `scripts/cuda-embed.rb` does for GPU images).
- `setup-poly.sh` fetches mruby from GitHub at the pin (and needs `ruby` + `rake` once), like `setup-mruby.sh`.

## Checks run

`tests/poly/run.sh` on both back ends (the host prints how many checks it ran), 8 repeated runs of each binary, each
binary under valgrind (`-q --error-exitcode=9`, no errors reported), and the control build described above.
