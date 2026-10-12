# nfcast: a self-specializing AST interpreter (milestone 1)

`lib/ast` is an interpreter for a Lua 5.4 subset written in C++ and built by nfcxx. It is the first of three steps towards
what GraalVM's Truffle does for a language, and only the first is done:

1. **An AST evaluator whose nodes specialize themselves** (this note). The source becomes a tree of nodes that evaluate
   themselves. A node starts generic, looks at the types that reach it, and replaces itself in its parent by a specialized
   node (integer addition, a table field with an inline cache, a call of a known kind). A specialized node guards what it
   assumed and replaces itself by the generic node when the guard fails.
2. Not done: tiering. A hot function would be lowered to C++, compiled through the `nfceval` path (`eval.md`; a tiny
   translation unit takes 0.5 to 0.7 s to compile here, 0.49 s on the gcc back end and 0.67 s on qbe, so it would run in the
   background) and called in place of the tree, with the guards of the specialized nodes becoming run-time checks.
3. Not done: inlining. Small script functions inlined at the AST level before lowering, and host functions inlined by the C
   compiler when the generated code can see their bodies. That last part works today for ordinary C++: a loop calling an
   `inline` function from a header compiles to a loop without a call on both back ends (checked by disassembling the object).
   What is missing is registering host functions by header and symbol instead of as type-erased callables.

There is no partial evaluation: that needs the interpreter to be data for a compiler, which nfcxx does not have. The
existing mruby, Lua and CPython backends of `nfcpoly` (`poly.md`) are bytecode VMs used as they are; this engine is the
fourth language of `nfcpoly`, `"ast"` (alias `"nfcast"`), with Lua syntax.

```cpp
nfcpoly::Context ctx;
ctx.bind_fn("scale", &scale);
int r = ctx.eval<int>("ast", "local s = 0 for i = 1, 100 do s = s + scale(i) end return s");
```

On its own (no nfcpoly):

```cpp
nfcast::State S;  S.open_libs();
std::string err;
nfcast::Closure* chunk = S.load("return 1 + 2", "snippet", &err);
nfcast::Rets out;
S.call(nfcast::Value::function(chunk), nullptr, 0, out);   // out.first() is the integer 3; a script error is a nfcast::Thrown
```

Tests: `tests/ast/run.sh` (the engine on its own, both back ends, in CI) and `tests/poly/run.sh` (the shared suite of every
language, plus `ast_tests()` and the cross-language checks, with `POLY_LANGS=ast` to run only this one). The engine needs
nothing built: the five `lib/ast/nfcast_*.cpp` files plus `-I lib/ast`.

## Layout

| File | Contents |
| --- | --- |
| `nfcast.hpp` | the public API: `Value`, the heap objects, `State`, `Thrown`, `HostObject` / `HostMember` |
| `nfcast_impl.hpp` | internals shared by the files: `Proto`, `Frame`, `Node`, the node factories, the operator slow paths |
| `nfcast_core.cpp` | strings, tables, the heap and its collector, `State`, errors, number and string conversion |
| `nfcast_ops.cpp` | metatables, the slow path of every operator, calls |
| `nfcast_parse.cpp` | lexer, recursive-descent parser, name resolution, constant folding |
| `nfcast_nodes.cpp` | the node classes and the specialization |
| `nfcast_lib.cpp` | `State::load` and the standard library |
| `../poly/nfcpoly_ast.cpp` | the `nfcpoly` backend |

## Values and the heap

A `Value` is 16 bytes: a tag and an integer, a double or a pointer. Nil, booleans, 64-bit integers (wrapping) and doubles are
plain; strings, tables, functions (script closures and native functions), boxes for captured locals and host objects are heap
objects in one list. Strings up to 40 bytes are interned (equal contents, equal pointer, which is what makes a field lookup a
pointer compare); longer ones are compared by content. A table has an array part for the keys `1..n` and a hash part with open
addressing; removing a key leaves a dead key that `next` can still find, so a loop may clear fields while it runs.

The collector is a precise stop-the-world mark and sweep. The roots are the interpreter stack (`[stack, top)`), the globals,
the string metatable, the pins the host holds (`State::pin`, which a `nfcpoly::Value` uses), and the values native code
registers in `extra_roots`. It runs only at **safe points**: entering a script function, an iteration of a loop, and
`collectgarbage()`. So a node that holds a collectable value in a C++ local while it evaluates another operand roots it first by
pushing it on the stack (`Pushed`), and the arguments of a call are evaluated straight onto the stack above the callee.
Allocation never collects, which is why a native function can build a result without rooting every piece. The strings the
nodes refer to are constants of their function (and of the functions nested in it, whether or not a closure of the inner one
exists yet), marked through the closures. `NFCAST_GC_STRESS=1` (or `State::gc_stress`) collects at every safe point; the
tests run every program that way.

A host object is a `HostObject` the host subclasses (its class key, its members, how it prints and compares) and the collector
deletes when it is unreachable. A `HostMember` is a property or a method. The nodes cache the member of the last class they saw.

## Specialization

Every dispatching node is a family: an uninitialized node, the specialized nodes, a generic node.

| Family | Specialized for | Guard that fails to the generic node |
| --- | --- | --- |
| arithmetic and bitwise | two integers; two numbers | a non-number (a string, a table with a metamethod) |
| `<` `<=` `>` `>=` | two integers; two floats | anything else |
| `t[k]` | a table and an integer key (the array part) | other types, or a hole with a metatable |
| `t.name` | a table (the index of the hash node, checked by key); a host object (member cached by class) | other types |
| `t[k] = v`, `t.name = v` | the same | other types, a metatable with `__newindex` |
| `f(args)` | a script closure; a native function | anything else (a `__call` object) |
| `obj:name(args)` | a table; a string (the string library); a host object (member cached by class, called without making a function value) | other types |

The uninitialized node does its first evaluation by choosing and replacing itself (`respec`), then finishes the evaluation in
the new node (`compute`, `get`, `put`, `run_with`), so the operands are evaluated once. A replaced node stays alive in the
arena of its function, because an activation may still be inside it. The rewrites are visible: `State::stats` counts
`rewrites`, `deopts` (a specialized node giving way) and `generic_ops` (slow paths taken), and `tests/ast/engine.cpp` checks
that an integer loop takes no slow path, that a float reaching an integer addition costs exactly one deopt and then runs on
float nodes, and that table fields and the array part stay off the slow path. `for ... in pairs(t)` and `ipairs(t)` run as
cursor loops over the table when the iterator is the original `next` or the `ipairs` iterator.

The parser folds constants like Lua's compiler does (`2^53`, `-1`, `1 << 62`; not a division by zero, and not a result that is NaN
or a float zero), which also matters for the names in error messages.

## Errors

A script error is the C++ exception `nfcast::Thrown` carrying the error value, so it unwinds the C++ frames of the host it
crosses and runs their destructors (the same exception runtime as every other `throw`; a bound function lets it pass). A
traceback is recorded only when nothing in the script can catch it (no `pcall` active). Messages and positions follow Lua
5.4.9 down to the details that differential testing found: `chunk:line:` prefixes, `(local 'x')` / `(field 'y')` /
`(upvalue 'z')` / `(constant 'k')` / `(method 'm')` names (including that Lua names the operand of `and` / `or` only where it
resolved the condition at compile time), `bad argument #1 to 'rep'` with the name used at the call site (the qualified
`string.rep` when `pcall` calls it, and no position then), `calling 'm' on bad self`, `error` levels counting the native
frames between script frames, and the `string` metamethod messages for arithmetic on strings
(`attempt to add a 'string' with a 'number'`).

The backend follows the exception rules of `poly.md`: errors it raises are tables `{class, message}` with a `__tostring`, a host
exception inside a script travels in the table's `host` field as a `std::exception_ptr`, and one that nothing rescued comes out
of `eval` as the original C++ exception. Runaway recursion is `stack overflow` after 1500 nested script calls
(`State::max_depth`): the evaluator recurses on the C++ stack, about a kilobyte per script call.

## The language

Lua 5.4 syntax and semantics: integers and floats with Lua's conversion and comparison rules, strings with the escapes, long
brackets and Lua patterns (`find`, `match`, `gmatch`, `gsub` with string, table and function replacements), closures with
a fresh local per loop iteration, varargs, multiple results, metatables (`__index`, `__newindex`, `__call`, `__tostring`,
`__eq`, `__lt`, `__le`, `__len`, `__concat`, `__unm`, `__bnot`, the arithmetic and bitwise events, `__pairs`, `__metatable`,
`__name`), `<const>`, `pcall`, `xpcall`, `error` with levels, `load` of a string. The libraries are base, string (`len sub upper
lower reverse rep byte char find match gmatch gsub format`), table (`insert remove concat unpack pack move sort`) and math
(`random` is Lua's xoshiro256**, so a seeded sequence equals Lua's).

Not there: coroutines, `goto` and labels, to-be-closed variables (`<close>`), `__gc`, `__close` and weak tables (`__mode` is
ignored), `utf8`, `string.pack` / `unpack`, `io`, `os`, `package`, `debug`, `dofile`, `loadfile`, a custom environment for
`load`, a function as the argument of `load`. Differences that a program can see: tail calls are ordinary calls (they count
against the depth limit); `table.sort` is a merge sort (stable, never reads out of bounds whatever the comparison does);
the order of `pairs` over a hash part differs from Lua's (the array part first, then the nodes); `xpcall`'s handler runs
after the stack has unwound, so it cannot inspect it; `collectgarbage("step")` always collects and returns `true`; the
table functions treat a table without a metatable raw and respect `__index` / `__newindex` / `__len` otherwise; `==` on two
host objects of one class compares the C++ objects; strings compare as bytes.

## Verification

- `tests/ast/cases/*.lua`: nine programs (arithmetic and number formatting, strings and patterns, tables, closures,
  metatables, errors and their messages, control flow, algorithms, garbage-heavy code). Each `.out` file next to them is the
  output of a real Lua 5.4.9 (`tests/ast/regen.sh`, built from the pin of `setup-poly-lua.sh`), and `tests/ast/run.sh` requires
  the same stdout from nfcast on both back ends, once normally and once with the collector at every safe point. Two of the
  programs had a syntax error in my first version and compared equal because *both* implementations refused them: the
  check now also requires that the reference run succeeds.
- `tests/ast/engine.cpp`: 71 checks through the C++ API (the specialization counters, the collector, host objects, errors, the
  state of the interpreter after errors, pins).
- `tests/ast/fuzz.sh` (not in CI): random programs, a few hundred seeds of each kind: arithmetic, bitwise, comparison,
  concatenation and logic over integers, floats, strings and other values, and calls of `find`, `match`, `gsub`, `gmatch` with
  random patterns. Equal output to the reference, error messages included, after fixing what it found: float modulo with two
  negative operands (`-2 % -2^63`), string operands of bitwise operators (an error in 5.4), and where Lua's error messages
  carry a variable name.
- The same programs under AddressSanitizer and UBSan with the collector at every safe point; the poly host under valgrind
  (the only leaks reported are the `ClassInfo` records of the core, which are never freed by design). A first version of
  `HostObject` converted the pointer to its collector header with `reinterpret_cast`, wrong for a class with a vtable; the
  engine test of host objects found it (the object was freed while a global still held it).
- Mutation checks on scratch copies: not marking the constants of nested functions, a `pcall` that restores nothing after an error,
  a table constructor that does not root its table, and an array part that does not take in keys waiting in the hash part each
  fail the checks written for them (the engine test or the stress runs of the programs). Removing the part of `pcall` that
  restores the native-call context changes nothing observable: the enclosing native call restores it anyway.
- `tests/poly/run.sh`: the shared suite (117 checks per language) passes for `"ast"` on both back ends, and in the same
  `Context` as Ruby, Lua and Python (559 checks in all).

## Speed

Measured once, on the host compiler (g++ -O2 for this engine, gcc -O2 for the reference Lua 5.4.9), best of three, seconds. Indicative
only; the back ends of nfcxx are not the same compiler.

| Program | Lua 5.4.9 | nfcast | |
| --- | --- | --- | --- |
| `fib(32)` (recursive calls) | 0.21 | 0.43 | 2.0x |
| two loops of 30 and 10 million additions and multiplications | 0.54 | 1.30 | 2.4x |
| 3 million array writes and reads, 200 thousand string keys, 10 million field reads | 0.54 | 0.69 | 1.3x |
| string building, `gmatch`, `find` | 0.37 | 0.30 | 0.8x |
| 3 million method calls allocating a table each | 0.68 | 0.82 | 1.2x |

A tree walker that rewrites itself is within a small factor of a register-VM written in C and tuned for years. Nothing here
claims what tiering or inlining would add; that is milestones 2 and 3.
