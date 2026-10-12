# nfcast: a self-specializing AST interpreter, a tier that compiles numeric kernels, and inlining (milestones 1 to 3)

`lib/ast` is an interpreter for a Lua 5.4 subset written in C++ and built by nfcxx. It is the first of three steps towards
what GraalVM's Truffle does for a language; the first two and, at the AST level, the third are done:

1. **An AST evaluator whose nodes specialize themselves** (this note). The source becomes a tree of nodes that evaluate
   themselves. A node starts generic, looks at the types that reach it, and replaces itself in its parent by a specialized
   node (integer addition, a table field with an inline cache, a call of a known kind). A specialized node guards what it
   assumed and replaces itself by the generic node when the guard fails.
2. **Tiering** (the section "Tiering" below; off unless a `State` is given options). A hot function that is a numeric kernel
   is lowered to C++, compiled by the nfcxx driver into a shared object (cached on disk by a hash of the source, loaded with
   `dlopen`: the path of `nfceval`, `eval.md`) and called in place of the tree. What the compiled code assumes is checked at
   every entry, and a run that fails half way is redone in the interpreter, so the compiled code never has to produce an error
   itself. `fib(32)` takes 0.03 s instead of 0.93 s on the gcc back end once the code is compiled (a compile of a small unit takes
   about 0.2 s on either back end).
3. **Inlining of small script functions at the AST level** (the section "Inlining" below): a hot call site evaluates a private
   clone of a small callee's body instead of calling it. Not done, and out of scope here: host functions inlined by the C
   compiler when the generated code can see their bodies. That works today for ordinary C++: a loop calling an `inline`
   function from a header compiles to a loop without a call on both back ends (checked by disassembling the object). What is
   missing is registering host functions by header and symbol instead of as type-erased callables.

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

Tests: `tests/ast/run.sh` (the engine, its tier and its inlining on their own, both back ends, in CI) and `tests/poly/run.sh`
(the shared suite of every language, plus `ast_tests()` and the cross-language checks, with `POLY_LANGS=ast` to run only this
one). The engine needs nothing built: the six `lib/ast/nfcast_*.cpp` files plus `-I lib/ast` (`nfcast_inline.inc` is included by
`nfcast_nodes.cpp`; the tier needs the nfcxx driver only when it is switched on).

## Layout

| File | Contents |
| --- | --- |
| `nfcast.hpp` | the public API: `Value`, the heap objects, `State`, `Thrown`, `HostObject` / `HostMember` |
| `nfcast_impl.hpp` | internals shared by the files: `Proto`, `Frame`, `Node`, the node factories, the operator slow paths |
| `nfcast_core.cpp` | strings, tables, the heap and its collector, `State`, errors, number and string conversion |
| `nfcast_ops.cpp` | metatables, the slow path of every operator, calls |
| `nfcast_parse.cpp` | lexer, recursive-descent parser, name resolution, constant folding |
| `nfcast_nodes.cpp` | the node classes and the specialization |
| `nfcast_inline.inc` | inlining: the cloner, the inlined call nodes, the rules (included at the end of `nfcast_nodes.cpp`) |
| `nfcast_lib.cpp` | `State::load` and the standard library |
| `nfcast_tier.cpp` | the tier: lowering, types, source text, the compile and its cache, the entry guards, the hooks |
| `nfcast_tier.hpp` | what the tier shares with the engine: the hooks and `TierView` (a node as the tier sees it) |
| `nfcast_tier_view.inc` | `#include`d by `nfcast_nodes.cpp`, where the node classes are: turns a node into a `TierView` |
| `nfcast_tier_rt.h` | the numeric operators, written once for the interpreter and for the generated code |
| `../eval/nfceval_build.hpp` | finding the driver, the cache directory, running the driver, `dlopen`: the half of nfceval that the tier shares |
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
| `f(args)`, `obj:name(args)` after the site has called a small script function a few times | the body of that function inlined (see "Inlining") | a callee that is not a closure of the same function |

The uninitialized node does its first evaluation by choosing and replacing itself (`respec`), then finishes the evaluation in
the new node (`compute`, `get`, `put`, `run_with`), so the operands are evaluated once. A replaced node stays alive in the
arena of its function, because an activation may still be inside it. The rewrites are visible: `State::stats` counts
`rewrites`, `deopts` (a specialized node giving way) and `generic_ops` (slow paths taken), and `tests/ast/engine.cpp` checks
that an integer loop takes no slow path, that a float reaching an integer addition costs exactly one deopt and then runs on
float nodes, and that table fields and the array part stay off the slow path. `for ... in pairs(t)` and `ipairs(t)` run as
cursor loops over the table when the iterator is the original `next` or the `ipairs` iterator.

The parser folds constants like Lua's compiler does (`2^53`, `-1`, `1 << 62`; not a division by zero, and not a result that is NaN
or a float zero), which also matters for the names in error messages.

## Inlining

Milestone 3, at the AST level: a call of a small script function is replaced, at the call site, by a private copy of the
function's body. `lib/ast/nfcast_inline.inc` has the code (textually included at the end of `nfcast_nodes.cpp`, because the
node classes it clones live in that file's anonymous namespace).

**When.** A call site `f(args)`, or a method call `obj:m(args)` whose receiver is a table, counts the executions in which the
callee was a script closure (`State::inline_warm`, 2 by default). At the count it asks whether the callee is a candidate; if so
the node rewrites itself into an `InlineCall` / `MethodInline`, and the executions after that one are inlined. A site that
asks once and is refused is not asked again. The first execution of a site (the uninitialized node) and the one that rewrites it
are ordinary calls.

**What is a candidate.** A script closure that is not a vararg function, has at most 16 parameters and locals, and whose body
clones to at most 64 nodes out of: constants, locals, upvalues, globals, arithmetic / comparison / logic / concatenation, field
and index reads and writes, table constructors, calls and method calls (which become uninitialized call nodes of their own),
local declarations, single assignments (local, upvalue, global, field, index), `if` chains, `return`. Not candidates: a body
with a function expression or a local function (a closure would capture the callee's frame), `...`, a loop or `break`, a
multiple assignment (`a, b = b, a`), or any node class the cloner does not list (so a node class added later is refused until
someone teaches the cloner about it). A callee that is a native function, a host method, an object with `__call` or a string
method is not a script closure and is never inlined; a method call whose receiver is not a table is not inlined either.

**What runs.** The inlined call does what the call node did (the callee expression first, then the arguments left to right
onto the interpreter stack, extra arguments evaluated and dropped, missing ones nil, a multi-valued last argument expanded),
then checks the guard, then evaluates the clone in a `Frame` of its own that sits on the C++ stack and is linked into
`State::cur` like the frame of a real call: the callee's closure, its arguments in place on the stack as its first slots, its
other locals above them, the depth counted and the collector's safe point at the entry. A body that is a single
`return <expr>` is evaluated as the expression, without a block, a return node or a results vector (a longer body keeps its block
and return nodes and the results vector). What the inlined call saves is therefore the call itself (the dispatch and the call
set-up, for a single `return` also the block, the return node and the results vector), and what it adds is a private,
per-site profile: the clone is made from the callee's tree in the *uninitialized* form (a specialized arithmetic node becomes
the uninitialized arithmetic node again, a field cache is empty), so it specializes on what this site sends it. A helper that
sees integers at one site, floats at another and strings at a third has an integer, a float and a generic copy, where the
shared tree gives way to the generic nodes for all three (`tests/ast/engine.cpp` counts the slow paths of exactly this).

**The guard** is the callee's `Proto::uid`, a number that is never reused (an address is: a collected function's proto can be
freed and another allocated in its place). It identifies the function, not the closure: closures of one function with different
upvalues pass it and read their own, because the clone's upvalue nodes read through the frame's closure. A value that does not
pass (another function, a native, a table with `__call`, nil, a method that changed under a method site) rewrites the node
back into the generic call node, counts a deopt, and the site is not inlined again (a site that alternates between two functions
would otherwise pay for a clone at every change).

**Why a frame of its own.** The obvious design is to evaluate the clone in the caller's frame, with the callee's slots renumbered
into slots added to the caller's `Proto`. That is unsound for the activations that are already running: a frame has the size it
was entered with, so slots added later overlap the temporaries of the evaluation in flight (the arguments of a call being built,
a rooted table). It would also lose what makes the inlined call invisible: the position `chunk:line:` of an error must be the
callee's even when the callee comes from another chunk, `error(msg, 2)` must blame the call site, a traceback must have an entry
for the callee, and the depth limit must count it. A frame of its own gives all of that for free, because everything that
looks at the frame chain (`rt_error`, `where`, `traceback`) finds the same chain as for a real call. The price is the frame
set-up, part of the roughly 100 instructions an inlined call still costs (see "Speed").

**Recursion and growth.** A function may occur at most twice in a chain of inlined bodies (a recursive call is unrolled once,
the copy's own recursive call stays a call), a chain has at most four frames, a function takes at most 8192 nodes of clones in
all (the size of the function itself does not matter), and every inlined call counts against `State::max_depth`, so runaway recursion is still a
`stack overflow` after the same number of nested calls with and without inlining (tested: the engine counts the nested calls
both ways). Nested inlining arises by itself: the clone of a function whose body calls a small function contains an
uninitialized call node, which becomes an inlined call when it is hot (tested for chains of six calls; the exact limits of two
occurrences and four frames are not tested, only that a recursive function is unrolled a few levels and not without end).

**Collector.** The clone belongs to the arena of the function that owns the site (the nodes it creates when it rewrites itself
too: `owner_proto` skips the inlined frames), and the strings its nodes refer to are added to that function's constants. Both
are defensive: while a clone can run, the callee's closure is on the stack and the callee's own constants are marked, and no test
can tell the difference (removing either keeps every check green; see "Verification").

**Switching it off.** `NFCAST_INLINE=0` in the environment, or `State::inlining = false` before a script is loaded
(`NFCAST_INLINE_WARM=n` / `State::inline_warm` sets the count; 0 means never). The setting is read when a site is created and
when it reaches its count, so changing it later does not take back a site that was already rewritten. Counters:
`State::stats.inlined_sites` (sites rewritten), `inlined_calls` (calls run as inlined bodies), `inline_declined` (sites that were
looked at and left as calls); a guard that fails counts in `deopts`.

**What the tier does with it.** `InlineCall` and `MethodInline` are ordinary call nodes (`CallBase`, `MethodBase`) that hold an
`InlineBody`: the callee's `uid`, and the clone of the body or of its single return expression. The tier lowers an `InlineCall`
as the call it was (`nfcast_tier_view.inc` sees a `CallBase` with `fn_` and `args_` and ignores the clone), so the callee is found
and checked at every entry like at any other call and a function whose sites were inlined is still a candidate for the tier. A
call that is inlined does not go through `call_closure`, where the tier counts calls and enters compiled code: such calls do not
count towards the callee's threshold, and when the interpreter reaches an inlined site it runs the clone even if the callee was
compiled meanwhile. That is the case where the tier gains little anyway (a small callee without loops called from interpreted
code; inlined bodies have no loops). `MethodInline` is a method call on a table, which the tier does not compile (such a function
is ineligible with or without inlining). The configurations "tier+inline-early" of `tests/ast/run.sh` run every program with
both, with every site rewritten at its second call and every function compiled at its first.

**Not done, and out of scope.** Host functions inlined by the C compiler when the generated code can see their bodies (the
remaining half of the third step above) still needs host functions registered by header and symbol; this milestone does not
touch it. Inside the engine: no loops in an inlined body, no closures, no `...`, no multiple assignment; no parameter
substitution (an argument is always evaluated into a slot, so `sq(x)` is not rewritten to `x * x`); no re-inlining of a site
after a guard failed; the clone is made once, from the callee's tree at that moment, and does not follow later changes to it
(the tree only ever rewrites itself into equivalent nodes, so the copy stays correct, only possibly less specialized).

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
(`State::max_depth`): the evaluator recurses on the C++ stack, about a kilobyte per script call. An inlined call (below) has a
frame in this chain like any other, so positions, `error` levels, tracebacks and the depth limit do not depend on whether a call
was inlined.

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
Three more that the tests of the inlining ran into (they exist with inlining on and off, and are worked around in the programs
with a comment, not fixed): an error message about a value read with a variable key (`t[k].x` with `t[k]` nil) says `(field '?')`
in Lua and has no name here; the errors of integer division and modulo by zero have no position in Lua when an operand is a
string (the string metamethod raises them) and have one here; and because a tail call is an ordinary call, `error(msg, 2)` in a
function that was called as `return f()` blames the function that made the tail call here; in Lua that function's frame is
gone, and level 2 is its caller.

## Tiering

The tier is **off unless a `State` is given options**: `nfcast` itself has no run-time dependency on the nfcxx driver, and the
default `State` never starts a process.

```cpp
nfcast::State S;  S.open_libs();
nfcast::TierOptions t;     // Sync, 2000 calls or 50000 loop iterations; the driver is found the way nfceval finds it
S.enable_tier(t);          // t.mode = nfcast::TierOptions::Async: compile in the background (a child process)
```

For the test drivers the environment does the same when the `State` is created: `NFCAST_TIER=sync|async|0`,
`NFCAST_TIER_THRESHOLD=n` (calls and loop iterations; the tests use 1), `NFCAST_TIER_CACHE=dir`, `NFCAST_TIER_RT=dir` (where
`nfcast_tier_rt.h` is, if not next to `nfcast_tier.cpp`), `NFCAST_TIER_DEBUG=1` (what it compiles, loads and refuses, on stderr);
the driver is `$NFCXX`, else `<repo>/nfcxx`, else `nfcxx` on `PATH`. `State::tier_state(fn)` says what became of a function
(`cold`, `compiled ii->i`, `ineligible: why`, `failed ...`), `State::tier_wait()` waits for the compiles that are running. The other
fields of `TierOptions` are `threshold` and `loop_threshold`, `jobs` (compiles running at once in `Async`), `driver`, `cache_dir`,
`rt_dir` and `timeout`.

### When, and what

Every call of a script function that no compiled code served counts for it, and so does every iteration of its loops (a second
counter). When one reaches its threshold, the function is looked at: if it is a numeric kernel it is lowered for the types of
the arguments of that call (of its parameters as they are when a loop triggers it), compiled, and its next calls with arguments
of those types run as native code. A function has up to four versions (other argument types); a call that no version fits runs
in the interpreter and counts towards the next one (the count starts again at every compile, so another set of argument types
has to earn its own). A function that is not a kernel is looked at three times, with growing
gaps, and then left alone for good (`tier_ineligible` counts it once).

A **numeric kernel** is a function whose body has only:

| In the body | |
| --- | --- |
| parameters, locals, loop variables | integers, floats, booleans, or numbers of either kind (below); **one type for the whole function** per variable |
| constants | integers, floats, `true`, `false` |
| arithmetic `+ - * / // % ^`, unary `-` | with the interpreter's integer and float rules (wraparound, `//` and `%` rounding down, `/` and `^` always float, `x // 0.0`) |
| `& \| ~ << >> ~x` | on integers, and on numbers of either kind (a float with an integer value is converted; any other abandons the run); not on a float that is one for certain |
| comparisons, `== ~=`, `and`, `or`, `not` | an integer against a float is compared exactly; `and` / `or` on booleans, or as conditions |
| `local`, assignment (also several at once), `if` / `elseif` / `else`, `while`, `repeat`, numeric `for` (integer and float loops), `break`, `return` with one value or none | |
| reads of upvalues and globals | numbers and booleans, read again at every entry |
| calls of a script function through an upvalue or a global, as an expression or a statement | itself, mutual recursion, other kernels |

and nothing else: no tables, strings, closures, varargs, assignments to upvalues, globals or fields, native functions (the math
library included), method calls, function values used as values (as arguments, say), several results. A function with any of
those simply stays interpreted.

The lowering does not read the specialized state of the arithmetic and comparison nodes (`ArithII`, `ArithNN`, `CmpFF` ...):
they record that a node saw only integers, or numbers, but not which numbers an `ArithNN` met, and a node that was never
evaluated has not specialized at all. It recomputes the types from the operands with the rules the specialized nodes encode
(integer op integer is an integer for `+ - * // %`, anything with a float is a float, `/` and `^` are floats, a comparison is a
boolean): the types of the parameters come from the arguments of the call, constants and the results of calls follow. A
variable, parameter or result that gets an integer in one place and a float in another (`local s = 0 ... s = s + 0.5`) is a
**number of either kind** (`n` in `tier_state`, as in `compiled if->n`): the generated code keeps it as an `nfcr_N`, the value
and a 64-bit flag that says which, and its operators (`nfcr_nadd`, `nfcr_nlt` ...) do what the interpreter's do on two numbers: an
integer with an integer gives an integer (wrapping), anything with a float a float, so `s` is the integer `0` for as long as the
loop has not run and the result of the function has the kind the run gave it (`acc(0, 0.5)` is `0`, `acc(4, 0.5)` is `2.0`). An
arithmetic operation on one of these and an integer is one again, on one and a float a float. A function is refused when the
result depends on the values in a way that does not fit that: a boolean and a number in one variable or result, a path that
returns a value and another that falls off the end, a bitwise operation on a float that is one for certain, an order comparison of
booleans, a `for` loop whose start or step is a number of either kind (it counts in integers or in floats depending on them; its
limit may be one).

### Soundness

The compiled code has **no side effects**: it reads its arguments and the values of the upvalues and globals it uses, and
returns a number, a boolean or nothing. It allocates nothing, so it needs no safe point, and calls nothing that is not a kernel.
That is what lets every assumption that fails be handled by *abandoning the run and doing the whole call again in the
interpreter*, with nothing to undo:

- **Entry guards**, checked by the engine before every run: the argument tags are those of the version; for every function the
  code calls, the upvalue or global that names it holds a closure of the function that was compiled (checked by identity of
  the function, not of the closure, so the closures of one function made by a factory work, each with its own upvalues);
  every upvalue and global it reads has the type it had; the recursion fits under `State::max_depth` and the value stack. The
  values of the free variables are collected at the same time. Nothing runs between the check and the end of the run, so the
  answer holds for the whole run. A guard that fails is `tier_guard_misses`; the call is interpreted.
- **A run that fails half way**: an integer `//` or `%` by zero (also two numbers of either kind that turn out to be integers),
  a bitwise operation on a float without an integer value, a `for` loop with a step of zero, a recursion that reaches
  `State::max_depth` (these are the places where the generated code calls `nfct_bail`) jumps back to the entry with a
  `longjmp`, which costs nothing on the way in, and the engine redoes the call in the interpreter. That finds the same error
  with its message, its position and its traceback (or, for a recursion that was too deep, the `stack overflow`), and, for a
  call that was only abandoned, the same result. `tier_aborts` counts them. A version that aborts in more than a quarter of its
  runs, after eight aborts, is given up.
- **The same arithmetic**: the integer and float operators, the shifts, the comparison of an integer with a float and the
  arithmetic of a numeric `for` loop are in `nfcast_tier_rt.h`, which the interpreter includes and the generated code pastes
  into its source; the interpreter's own copies were removed. `pow` is called through a pointer the C compiler cannot see through,
  so that it does not fold `pow(2.0, 0.5)` with its own correctly rounded result where the interpreter calls the library.
- **The order of evaluation**: C leaves the order of operands open; a program in which the first of two operands raises an
  error and the second loops for ever must still fail, so an operand with a call or a division in it that is followed by another
  such operand goes into a temporary first.
- **Depth**: the compiled calls count like `State::depth`, with the same limit (`stack overflow` comes from the interpreter
  after the abandoned run), and the code is not run at all when the interpreter's value stack could not hold that many frames of
  the unit.

What the tier does not promise: timings; *when* the collector runs (compiled code has no safe points, so a program that watches
`collectgarbage("count")` sees other numbers); and the **sign of a NaN**, which `print` shows (`nan` or `-nan`). The interpreter's
operations make the processor's NaN; the front end folds `0.0 / 0.0` to a positive one, so an operation on two literals goes
through a call the compilers cannot see through (checked in `tier.cpp`), but nothing else was done about a C compiler that folds
a NaN-making operation it can follow through locals (not seen with gcc here). On a target where the C compiler fuses a multiplication
and an addition (aarch64, `__aarch64__` / `__FP_FAST_FMA`) the last bit of a float result could differ, and the tier does not compile
float kernels there: that code is untested, there is no such host in the tests.

### Compiling

`request` builds the unit: the function and the kernels it calls, found through the bindings at that moment; types them for the
argument types of the call (one instance per combination of argument types, found by iterating to a fixed point, which is also
how a recursion gets its result type); writes C++ with one `static` function per instance on unboxed `long long`, `double` and `nfcr_N` and an entry point `nfcast_tier_run(ctx, args, result)`; pastes `nfcast_tier_rt.h` in front; and hashes the text with the
driver's path and `NFCXX_BACKEND`. If `<cache>/nfcast-tier-<hash>.so` exists it is loaded (`tier_cache_hits`, no process runs: a
second `State`, or a second run of the program, compiles nothing); if not, `nfcxx -shared` makes it (`tier_compiles`; about 0.2 s for a
small unit on either back end) and it is installed with a rename, so that another process building the same code
never sees half a file. The source stays next to it as `.cpp`. The cache directory is created with mode 0700 and refused unless
the user owns it and nobody else can write to it, because the shared objects in it are executed (nfceval's rule; the cache is
never cleaned). Nothing generated depends on addresses or on the State: the text of a program's kernels is the same on every run.

The generated code includes only `<setjmp.h>` and declares the three libm functions it needs itself, which makes it compile twice
as fast as with `<math.h>` (0.22 s against 0.45 s on gcc, 0.24 s against 0.54 s on qbe, best of five, for the unit of `fib`).

`Sync`: the call that makes a function hot waits for the compile and then runs the new code. `Async`: the engine starts the
driver as a **child process** and goes on; the calls it serves afterwards look at the process now and then, and a call after it
has ended picks the code up. At most `TierOptions::jobs` (2) run at once, the others wait. There is no compile thread, and the
reason is not taste: EDG's exception runtime keeps one global stack of try blocks (`lib_src/throw.c` of the front end; the
interpreter pushes on it all the time, to run destructors when a script error unwinds), so a second thread running C++ code with
destructors while the engine runs would corrupt it (`__curr_eh_stack_entry` is a plain global in `3rd/edg/lib_src/eh.h`; that is from reading
the source: no thread was run to watch it fail). A State that is destroyed with compiles running kills them. A failed compile
(no driver, the driver exits non-zero, a timeout, a bad `dlopen`) is `tier_failed` and nothing else: the function stays
interpreted.

### Counters

`State::stats` gets: `tier_compiled` (versions that became callable: compiled or loaded), `tier_compiles` (driver runs),
`tier_cache_hits`, `tier_ineligible`, `tier_failed`, `tier_calls` (calls that ran as native code; a recursion inside one run is one
call), `tier_bailouts` (calls of a function that has compiled code that nevertheless ran in the interpreter), of which
`tier_guard_misses` (an argument or a binding the code did not assume) and `tier_aborts` (a run abandoned half way).

### Limits

- **No on-stack replacement.** A loop is counted, but a function that is called once and runs a hot loop is compiled for its
  *next* calls; the loop of the main chunk never is (it is a vararg function). `for i = 1, 1e8 do s = s + i end` at the top
  level of a script stays interpreted.
- Only the shapes above. In particular calls of native functions (`math.sqrt`, `math.floor`), tables and function values stay
  interpreted.
- Types are static: a variable is an integer, a float, a boolean or a number of either kind for the whole function; one that is a
  boolean and a number, or a function called with a string or a table, is not compiled. A number of either kind carries its flag and
  tests it in every operation, so it is slower than a plain `double`. At most four versions
  per function, 12 parameters, 24 functions in a unit, 48 typed instances.
- A toolchain finding, kept in `nfcast_tier_rt.h` as a comment: the QBE back end (cproc and QBE) miscompiles a struct that has a
  4-byte member next to padding and is copied by value, as the generated code copies an `nfcr_N`: it tests the wrong half of the
  word (a float came back as its integer part). `nfcr_N`'s flag is a 64-bit word for that reason. It was found by comparing a small
  accumulator with real Lua; with a 32-bit flag put back, 4 checks of `tier.cpp` and `tier_kernels.lua` fail on qbe. Not reported upstream.
- A kernel that fails often costs the failed run plus the interpreter's run until it is given up.
- Entering native code from the interpreter costs about as much as a call of a small function in the interpreter (the checks, a
  `setjmp`): a tiny kernel called from a loop in the interpreter gains little (ten million calls of
  `x * 2 + 1`, 0.54 s instead of 0.53 s); what gains is a kernel with a loop or a recursion inside, which runs inside one entry.
- The engine's own deviations from Lua are the tier's: a float `for` loop with a NaN start does not run its body (Lua runs it once),
  and an integer loop with a NaN limit and a negative step does not run (Lua counts down to `math.mininteger`).
- It needs POSIX (`fork`, `dlopen`), the nfcxx driver and the `lib/ast` directory next to it at run time.

## Verification

- `tests/ast/cases/*.lua`: ten programs (arithmetic and number formatting, strings and patterns, tables, closures,
  metatables, errors and their messages, control flow, algorithms, garbage-heavy code, numeric kernels) and, for the inlining, ten more named
  `inline_*` (argument adjustment and the order of evaluation; errors raised inside inlined bodies: message, position, variable
  names, `error` levels 0 to 3, error values that are not strings, `pcall` inside and outside, a callee from another chunk, natives
  called with bad arguments; a callee that is assigned again after its site was rewritten, a closure of the same function with
  other upvalues, a native or a `__call` table or nil in its place, methods replaced in the class or shadowed in the instance;
  upvalues read and written; arguments of every type, with metamethods; recursion, mutual recursion, runaway recursion and a deep
  legal one; chains of calls deeper than the inliner goes; methods, inheritance, receivers of different classes at one site;
  bodies with locals, `if` chains, assignments, no result and several; allocation for the collector). Each `.out` file next to
  them is the output of a real Lua 5.4.9 (`tests/ast/regen.sh`, built from the pin of `setup-poly-lua.sh`), and
  `tests/ast/run.sh` requires the same stdout from nfcast on both back ends, with the collector at its default and at every safe
  point, each with inlining as it is by default, with a site rewritten as soon as it is used twice (`NFCAST_INLINE_WARM=1`) and
  with inlining off (`NFCAST_INLINE=0`); and with the tier on and every function compiled at its first call (`NFCAST_TIER=sync`,
  `NFCAST_TIER_THRESHOLD=1`): normally, with the collector stress, with early inlining, and with the tier compiling in the
  background (`NFCAST_TIER=async`): 20 programs, 10 runs each, per back end. Two of the first programs had a syntax error in my
  first version and compared equal because *both* implementations refused them: the check also requires that the reference run
  succeeds (`regen.sh` and the helper that wrote the `inline_*` outputs refuse a reference that fails or prints to stderr).
- `tests/ast/engine.cpp`: 139 checks through the C++ API (the specialization counters, the collector, host objects, errors, the
  state of the interpreter after errors, pins) and, for the inlining, with `State::stats`: a loop of calls rewrites its site once
  and runs the rest inlined (97 of 100 calls with the default count, 98 with `inline_warm = 1`), a state with inlining off or
  `inline_warm = 0` inlines nothing; the guard fails exactly once when the global is assigned again (to another function, a
  native, nil) and the site is not rewritten again; closures of one function with other upvalues do not fail it; three sites
  that send integers, floats and strings to one helper take about 100 slow paths with inlining and at least 295 without
  (the shared tree goes generic); methods (a getter, an instance that shadows it); loops, varargs and multiple assignment are
  declined and counted, closures too, a body over the size limit too, a chunk with 3500 sites of a three-node function
  inlines about 2700 of them and declines the rest (the limit on the clones one function takes), with the same result; recursion
  inlines a few levels and the depth limit gives the same number of nested calls with and without inlining; the
  error raised three calls deep has the same message and the same traceback (four entries, with the lines and the names) with
  inlining off, on, and with every site rewritten as early as possible, in which case the error is raised inside three inlined
  bodies; the host calling back into the script from inside an inlined body and an error coming back through the inlined frames
  (the state of the interpreter after it); the collector at every safe point over bodies that allocate; a callee dropped by the
  program while a caller holds a rewritten site.
- `tests/ast/fuzz.sh` (not in CI): random programs, a few hundred seeds of each kind: arithmetic, bitwise, comparison,
  concatenation and logic over integers, floats, strings and other values, calls of `find`, `match`, `gsub`, `gmatch` with
  random patterns, and (`fuzz/gen_inl.py`) random small helper functions and methods of two classes called from random
  expressions, each expression run over ten tuples of argument values and three receivers so that the sites are hot when the
  types change; the helper programs run with the default count, with `NFCAST_INLINE_WARM=1` and with inlining off. Equal output
  to the reference, error messages and their positions included, after fixing what it found: float modulo with two negative
  operands (`-2 % -2^63`), string operands of bitwise operators (an error in 5.4), and where Lua's error messages carry a variable
  name. 300 seeds of each kind (the helper kind three times) ran without a mismatch for the inlining.
- The same programs under AddressSanitizer and UBSan with the collector at every safe point; the poly host under valgrind
  (the only leaks reported are the `ClassInfo` records of the core, which are never freed by design). A first version of
  `HostObject` converted the pointer to its collector header with `reinterpret_cast`, wrong for a class with a vtable; the
  engine test of host objects found it (the object was freed while a global still held it).
- Mutation checks on scratch copies: not marking the constants of nested functions, a `pcall` that restores nothing after an error,
  a table constructor that does not root its table, and an array part that does not take in keys waiting in the hash part each
  fail the checks written for them (the engine test or the stress runs of the programs). Removing the part of `pcall` that
  restores the native-call context changes nothing observable: the enclosing native call restores it anyway.
- Inlining under AddressSanitizer, UBSan and LeakSanitizer (g++ -O1): the engine test and every program in every
  configuration above, clean.
- Mutation checks of the inlining, on scratch copies, each against the engine test and every program (inlining by default and
  as early as possible, the collector at its default and at every safe point, built with the sanitizers): a guard that does not compare the function
  (fails the engine checks and `inline_redefine`, `inline_methods`); an inlined body that does not link its frame into
  `State::cur` (fails the traceback checks and six programs); no nil-fill of missing arguments (fails `inline_args` and, for the
  locals only, the programs under the collector at every safe point, which then reads garbage); the call-site line not set before
  the body runs (fails `inline_recursion`, the one program where the line of a level-2 error differs); no depth count (fails the
  state checks and the runaway recursion); an expression body that returns its first value instead of all (fails `inline_nested`
  and `inline_errors`); no limit on the clones one function takes (fails the engine check for it). Two mutations are **not**
  caught by anything: not adding the clone's strings to the owner's constants, and allocating the nodes that clones create in the arena of the
  callee instead of the owner's (`owner_proto`). Both are properties that nothing can observe while a clone can run (the callee's
  closure is on the stack, its constants are marked, its arena is alive), and are kept as defences, not as tested behaviour.
- `tests/poly/run.sh`: the shared suite (117 checks per language) passes for `"ast"` on both back ends, and in the same
  `Context` as Ruby, Lua, Python and JavaScript (884 checks in all); `POLY_LANGS=ast tests/poly/run.sh` (146 checks) also passes
  with the inlining and the tier compiled in, on both back ends.
- `tests/ast/tier.cpp`: 205 checks of the tier through the C++ API, with the nfcxx driver of the build. The first compile and
  its counters; a float argument to an integer kernel (a bailout, later a second version); recursion; mutual recursion; numeric
  upvalues and globals that change their value and their type; numbers of either kind (accumulators that start as an integer,
  results and parameters of either kind, bitwise operators, `//` and `%` and comparisons around 2^53 on them, a call made while a
  variable still had the type it was later widened from); a function rebound after it was compiled (a local, a global,
  closures of one function with different upvalues); 54 programs run in a State without the tier and in one with it at
  threshold 1, which must print the same text, errors included (integer wraparound, `//` and `%` by zero with the line of the
  error, loops with every kind of bound, integer against float comparisons, shifts, NaN made from constants, recursion at and beyond
  the depth limit, ineligible shapes); the traceback of an error raised by the re-run; loops counting towards the threshold;
  functions that are not kernels; the limit of four versions; operands that can fail keeping their order (a check that would hang
  otherwise); the collector at every safe point; the second `State` finding the code in the cache (no driver run); a driver that does not
  exist, that exits 1, that makes nothing, and a damaged cache file; asynchronous compiles (with fewer jobs than compiles, and a
  `State` destroyed while one runs); a host that ignores `SIGCHLD`.
- `tests/ast/fuzz_tier.sh` (by hand): random numeric kernels (`fuzz/gen_kernel.py`: integer, float, boolean and "number of either kind" locals, parameters and results, every
  operator, `if` / `while` / `repeat` / `for`, `break`, upvalues and globals that change type between calls, calls between functions,
  recursion, functions without a result, wrong and missing arguments) run by a real Lua 5.4.9 and by nfcast with every function
  compiled at its first call, output and error messages compared. On the final code: 24 seeds of 10 functions on the gcc back end (321 functions compiled, 1251 calls ran as native code) and 25 seeds on qbe (268 and 1224), no mismatch. It also found two differences between the engine and
  Lua that have nothing to do with the tier (a float `for` loop whose start is NaN runs its body once in Lua and not at all here; an
  integer loop with a NaN limit and a negative step counts down to `math.mininteger` in Lua and does not run here), which the
  generator now stays away from.
- The tier test, the engine test and the programs of `tests/ast/cases` with the tier at threshold 1 and the collector stress, under
  AddressSanitizer and UBSan (host g++ for the engine, nfcxx for the generated code): no report.
- Mutation checks on scratch copies of `nfcast_tier.cpp`: 21 mutants, each breaking one guard or one rule (the check of the callee, of the argument types, of the types of the free variables; the integer `//` by zero left to the interpreter; the depth limit; a `for` step of zero; the exact comparison of an integer with a float, in the generated code and in the shared header, for `<`, `<=` and `==` and for each order of the operands; the order in which a multiple assignment stores; the number type's zero divisor, conversion for bitwise operators, `>`, widening and result kind; the instances that widened types leave behind). The tier test fails for 20 of them (one by running into its `alarm`), and the golden kernels program differs for 13; the mutant of the equality of an integer and a float of either kind passed at first, which is why the test now has a grid of every comparison around 2^53 and 2^63 on such numbers. The one it does not notice: the hoisting of operands that can fail into temporaries is not needed by this toolchain, which evaluates operands left to right, so removing it changes nothing here; the check that would hang without it only has teeth on a C compiler that evaluates the other way.
- `tests/eval/run.sh` passes with nfceval built on `nfceval_build.hpp`, `tests/poly/run.sh` with `POLY_LANGS=ast` too, both back ends.

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

A tree walker that rewrites itself is within a small factor of a register-VM written in C and tuned for years.

### What the inlining adds

`RUNS=5 tests/ast/bench.sh host gcc qbe` (programs in `tests/ast/bench/`, best of 5 runs, seconds; the machine was shared with other jobs, so times
move by 10% or more between runs; nothing asserts on them): `helpers` is 5 million iterations of a loop calling small math helpers
and predicates, a two-level call (`dist2` calls `sq` twice) and table accessors; `getters` is 3 million iterations of method calls
on objects with a metatable (`a:getx()`, `a:dot(b)` calling two getters, a setter); `fib` is `fib(32)`.

| Target | Program | inlining | off | |
| --- | --- | --- | --- | --- |
| host g++ -O2 | `helpers` | 2.11 | 2.56 | 1.21x |
| | `getters` | 2.12 | 2.51 | 1.18x |
| | `fib` | 0.47 | 0.46 | 0.98x |
| nfcxx, gcc back end | `helpers` | 3.53 | 5.52 | 1.56x |
| | `getters` | 2.48 | 4.15 | 1.67x |
| | `fib` | 0.84 | 1.00 | 1.19x |
| nfcxx, qbe back end | `helpers` | 5.56 | 8.65 | 1.56x |
| | `getters` | 4.44 | 6.11 | 1.38x |
| | `fib` | 1.31 | 1.39 | 1.06x |

The same reference Lua 5.4.9 takes 1.3 s on `helpers`, 1.2 s on `getters` and 0.15 s on `fib` on this machine, so the loops
that call small functions are still 1.6x (`helpers`) to 1.8x (`getters`) slower than Lua with the host compiler and inlining on, and
`fib` 3x.

Instructions, which do not depend on the load of the machine (callgrind, the host build, 100 thousand iterations of `helpers`,
60 thousand of `getters`, `fib(24)`):

| Program | inlining | off | |
| --- | --- | --- | --- |
| `helpers` | 458.0 M | 561.6 M | -18% |
| `getters` | 436.3 M | 513.6 M | -15% |
| `fib(24)` | 88.5 M | 89.3 M | -1% |

So what inlining removes is the call. From the callgrind profile of `helpers`: the real call path (`CallBase::eval`, dispatch,
`call_closure`, the block and return nodes, the results vector) costs about 250 instructions per call and the inlined one about
100, out of roughly 500 per call of a small function including the nodes of its body. The rest is the cost of the nodes, which
this milestone does not change: an argument is still evaluated into a slot and
read back by a local node, `sq(x)` is still a multiplication of two local nodes. That is the honest size of the gain for a tree
walker that inlines by cloning: 15% to 20% of the instructions in a loop made of small calls, and nothing for `fib`, where
the unrolled level contains the same two calls it replaced. On the nfcxx back ends the saving in time is larger than the saving in
instructions of the host build suggests (I counted instructions only for the host build); I did not look into why. The tier does not use the clones (see "What the tier does with it"): it compiles whole kernels, and
the inlining helps what stays interpreted.

### Speed of the tier

`tests/ast/bench_tier.sh` runs the programs of `tests/ast/bench` with the tier off and with it compiling every function at its first call
(wall seconds, one machine with four cores that other jobs were using, so the figures are good to about 20%; the interpreter and
warm-cache figures are the best of three, the cold-cache figure is one run). Every run prints what the interpreter prints.

| Program | back end | interpreter | tier, cache empty | tier, cache warm | |
| --- | --- | --- | --- | --- | --- |
| `fib(32)` | qbe | 1.35 | 0.35 | 0.03 | 45x |
| `fib(32)` | gcc | 0.93 | 0.24 | 0.03 | 31x |
| `intloop`: integer loop, 30 million iterations | qbe | 2.08 | 0.43 | 0.16 | 13x |
| `intloop` | gcc | 1.40 | 0.26 | 0.04 | 35x |
| `accum`: a sum that becomes a float, 30 million iterations | qbe | 1.73 | 0.38 | 0.08 | 22x |
| `accum` | gcc | 1.07 | 0.24 | 0.03 | 36x |
| `mandel`: Mandelbrot over a 200 by 200 grid | qbe | 0.43 | 0.30 | 0.03 | 14x |
| `mandel` | gcc | 0.30 | 0.25 | 0.02 | 15x |
| `integrate`: 20 integrations of 500000 steps | qbe | 2.72 | 0.45 | 0.16 | 17x |
| `integrate` | gcc | 1.68 | 0.25 | 0.02 | 84x |

"Cache empty" includes the compile (a few tenths of a second per function; the programs have one or two functions); "cache warm" is
every run after the first one of a program, when the shared object is only loaded. The last column is the interpreter's time over the
warm time; the warm times of a few hundredths of a second include starting the process and loading the object, so the quotients are
rough. The programs: `fib(32)`; ten calls of a function
that runs a loop of three million iterations of `s + i * 3 % 7` (`intloop`); the same shape with a sum that starts as the integer 0
and becomes a float, a number of either kind (`accum`); the Mandelbrot iteration count over a 200 by 200 grid (a `while` loop and a
multiple assignment on floats; 1.5 million iterations, so little time to gain on); twenty integrations of 500000 steps that call
another kernel through an upvalue and read a numeric upvalue.

What the tier does not help: the work has to be inside a function that is called, or called again after the loop that made it hot
(there is no on-stack replacement), and it has to be a kernel. A tiny kernel called from an interpreted loop gains little (ten
million calls of `x * 2 + 1` from a loop at the top level: 0.53 s to 0.54 s on the host compiler). With the tier off the
engine runs as fast as before the hooks: measured with the host g++ -O2, best of three, with the tier off
against the engine of the milestone-1 commit: `fib(32)` (with `fib(20)` and `fib(27)` before it) 0.44 s against 0.46 s; 5 million
calls of a function that reads a table field, so is not a kernel, and `fib(30)`, 0.44 s against 0.42 s; the loop of ten million calls of a
tiny kernel 0.53 to 0.61 s against 0.52 to 0.58 s over three repetitions; `intloop` 0.93 against 0.99, `mandel` 0.23 against 0.25,
`integrate` 1.02 against 1.08, `accum` 0.67 against 0.70: no difference beyond the noise of a machine that other jobs were using (about
10%). A `State` without a tier pays one pointer test per call and per loop iteration.
