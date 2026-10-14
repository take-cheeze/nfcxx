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
   about 0.2 s on either back end). A hot loop of a function that is called once (or of the main chunk) is compiled alone and taken
   over in the middle of the call (on-stack replacement, "Loops" below).
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
| `nfcast_tier.cpp` | the tier: lowering, types, source text, the compile and its cache, the entry guards, the hooks, the takeover of loops |
| `nfcast_tier.hpp` | what the tier shares with the engine: the hooks (a call, a loop iteration, a loop's entry and edge) and `TierView` (a node as the tier sees it) |
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
local declarations, assignments (single or multiple; local, upvalue, global, field, index targets), `if` chains, `return`, and
the loops: `while`, `repeat`, numeric `for`, generic `for` (and `break`). Not candidates: a body with a function expression or a
local function (a closure would capture the callee's frame), `...`, or any node class the cloner does not list (so a node class
added later is refused until someone teaches the cloner about it). **Why loops and multiple assignment are fine** (they were
refused in the first version, as untested rather than unsound): the clone runs in a `Frame` of its own that is linked like a
real call's, so a loop sees what it sees in a real call: its slots (the loop variables and the hidden slots of a generic `for`
are slots of the callee, which the frame has), `break` and `return` travel up the clone as the codes the block nodes already
pass, the collector's safe point at every back edge (`loop_edge`) finds the inlined frame on the chain, an error inside a loop has
the callee's position and traceback entry, and `tier_backedge` counts the iteration for the callee's prototype exactly as for a
real call (it reads the parameters of the frame, which is why a body with a loop keeps its arguments in their slots, see
"Arguments"). The node limit (64) still applies, so only small loops are inlined; what a loop saves is the same call overhead
once per call, which is why this matters for helpers called often with a short loop (a sum, a search, a swap). A callee that is a native function, a host method, an object with `__call` or a string
method is not a script closure and is never inlined; a method call whose receiver is not a table is not inlined either.

**What runs.** The inlined call does what the call node did (the callee expression first, then the arguments left to right
onto the interpreter stack, extra arguments evaluated and dropped, missing ones nil, a multi-valued last argument expanded;
see "Arguments" for how the cheap ones are done), then checks the guard, then evaluates the clone in a `Frame` of its own that sits on the C++ stack and is linked into
`State::cur` like the frame of a real call: the callee's closure, its arguments in place on the stack as its first slots, its
other locals above them, the depth counted and the collector's safe point at the entry. A body that is a single
`return <expr>` is evaluated as the expression, without a block, a return node or a results vector (a longer body keeps its block
and return nodes and the results vector). What the inlined call saves is therefore the call itself (the dispatch and the call
set-up, for a single `return` also the block, the return node and the results vector), and what it adds is a private,
per-site profile: the clone is made from the callee's tree in the *uninitialized* form (a specialized arithmetic node becomes
the uninitialized arithmetic node again, a field cache is empty), so it specializes on what this site sends it. A helper that
sees integers at one site, floats at another and strings at a third has an integer, a float and a generic copy, where the
shared tree gives way to the generic nodes for all three (`tests/ast/engine.cpp` counts the slow paths of exactly this).

**Arguments.** An argument that is a read of a local that is not boxed, of an upvalue, or a constant is pure: it runs no script
code, allocates nothing, and nothing can change what it reads before the callee starts. The site keeps a plan with one entry
per argument (`ArgPlan` in `nfcast_inline.inc`): such an argument is copied into its slot straight from its source, without the
virtual call to the argument node and the generic loop of `push_args`; any other expression is evaluated as before, in order, and
an expression that follows is evaluated with the earlier values rooted on the stack. An extra argument (beyond the parameters)
that is pure is not evaluated at all.

**Parameter substitution.** When the argument is a local or a constant, the parameter is never written by the body (no
assignment, no multiple assignment, no declaration or loop variable on its slot, found by a first dry clone of the body) and the
body has no loop, the clone does not read the parameter from the callee's frame: its `LocalNode` is replaced, in the clone, by a
`SubstLocal` that reads the caller's local (the frame `up` links back along the chain; `S.cur` is the caller's frame when the
callee's frame is made, so `prev` is the frame of the site, and a site inside a clone whose argument was itself substituted
reads two or more links back) or by a `SubstConst` that holds the constant. The slot of the callee is set to nil only so the
collector sees a valid value, and the argument is not evaluated or copied. Why it is sound: a local that is not boxed is written
by nobody but its own function, which is suspended for the whole call (a boxed one, captured by a closure, is not substituted: its
node is evaluated at the call like before; tested with a callee that changes it); a constant cannot change; an upvalue can (the
callee may call something that assigns it), so an upvalue argument is copied but never substituted; a global is not pure (it
can have `__index`) and is evaluated like any expression. Both substitute nodes describe themselves as `local 'x'` with the
callee's name for the parameter, so the messages of errors do not change (`attempt to perform arithmetic on a nil value (local
'x')` whatever the caller passed). When the guard fails the callee that runs for real needs the values in its slots:
`restore_args` copies them from the sources (they are still there) before the call, for the call site and the method site. A body
with a loop keeps its arguments in their slots because `tier_backedge` reads the parameters of the frame to decide what to compile.
A method call substitutes its explicit arguments, not the receiver (which is evaluated once and stored like before).
`State::stats.inline_substituted` counts the arguments substituted when a site is rewritten. What it saves: the store and the read
through a frame slot per argument and the evaluation of the argument node (callgrind: about 7 million of 244 million instructions in
the `helpers`-style loop of `bench/helpers.lua`, on top of 7 million for the plan itself, see "Speed").

**The guard** is the callee's `Proto::uid`, a number that is never reused (an address is: a collected function's proto can be
freed and another allocated in its place). It identifies the function, not the closure: closures of one function with different
upvalues pass it and read their own, because the clone's upvalue nodes read through the frame's closure. A value that does not
pass (another function, a native, a table with `__call`, nil, a method that changed under a method site) counts a deopt and
rewrites the node back. When the new value is a closure, the site becomes the plain call node of a closure again, with the
count of executions restarted, and is looked at for inlining again: a site that sees a function after another (a helper
replaced, a callback that differs between phases of the program) is inlined for the new one. This is bounded, `kInlineMaxRetry`
= 3 times per site (the count travels with the node through the rewrites), because a site that alternates between two functions
would otherwise pay for a clone at every change; after that, or when the new value is not a closure, it becomes the generic call
node and the site is not inlined again. (Tested: 200 calls that alternate between two functions at one site rewrite it 4 to 7
times in all, counting the other sites of the same program, not 100.)

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
looked at and left as calls), `inline_substituted` (arguments the clones of rewritten sites read where they are); a guard that
fails counts in `deopts`.

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
touch it. Inside the engine: no closures and no `...` in an inlined body; no substitution of an upvalue
or global argument, of the receiver of a method, or when the body has a loop (all explained above); no folding of a substituted
constant into its consumers (`sq(3)` still multiplies two constant nodes); the clone is made once, from the callee's tree at that moment, and does not follow later changes to it
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
`load`, a function as the argument of `load`. Differences that a program can see: `table.sort` is a merge sort (stable, never reads out of bounds whatever the comparison does);
the order of `pairs` over a hash part differs from Lua's (the array part first, then the nodes); `xpcall`'s handler runs
after the stack has unwound, so it cannot inspect it; `collectgarbage("step")` always collects and returns `true`; the
table functions treat a table without a metatable raw and respect `__index` / `__newindex` / `__len` otherwise; `==` on two
host objects of one class compares the C++ objects; strings compare as bytes.

**Tail calls** are proper ones. `return f(args)` (a call that is the whole of a `return`, a method call included, not `return (f(x))`)
marks its call node (`Node::tail`, set by `ReturnNode`, kept by every rewrite of the node). When the callee turns out to be a script
function (or an object whose `__call` is one), the node does not call it: it moves the callee and its arguments to the bottom of the
running frame (`tail_closure`) and returns; `call_closure` sees `Frame::tail_cl` after the body returned and runs the new function in
the same `Frame`, in a loop, so a chain of tail calls takes neither C++ stack nor interpreter stack nor depth, and the caller is gone
from the frame chain: `error(msg, 2)` blames the caller of the function that made the tail call, as in Lua, and a traceback says
`(...tail calls...)` after the entry of a frame that was entered that way. A native callee is called as usual (Lua keeps the caller's
frame for those too). The tier is asked about the callee again each time round the loop, like for a call. Two consequences for
the inliner: a tail site is never inlined (the inlined frame would sit above the caller's), and a callee whose body has a `return f(x)`
is not a candidate (a clone cannot replace its frame); both are decided in `nfcast_inline.inc` and `CallUninit` / `MethodTab`.
Native code made by the tier recurses in C, except for tail calls: a tail call of the function to itself is a jump in the native code
(`Gen::self_tail`, see "Tiering"), and so is a tail call of another function of the same unit with the same result type (`Gen::tail_jump`),
so a tail recursion of any depth between kernels runs in one entry too. A tail call between functions with results of different types still
recurses in C: a tail recursion of that kind deeper than the depth limit bails out of it, and the interpreter then runs it in constant stack.

An error message about a value read with a computed key (`t[k].x` with `t[k]` nil) says `(field '?')` as Lua's does, `t[1]` says
`(field 'integer index')`; and the errors of integer division and modulo by zero when an operand is a string have no position, like
Lua's (the string metamethod raises them). What is still different in error messages: a `<const>` local used as a key
(`local k <const> = "a"; t[k].x`) is a compile-time constant for Lua's compiler, which names it (`field 'a'`), and a variable here.
A numeric `for` loop follows Lua's `forprep` with a NaN: a float loop whose start or limit is NaN runs its body once, an integer loop
with a NaN limit does not run when it counts up and counts down to `math.mininteger` otherwise.

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
| assignments to upvalues | numbers and booleans; made on copies and written to the upvalues when the run has ended (see "Soundness") |
| calls of a script function through an upvalue or a global, as an expression or a statement | itself, mutual recursion, other kernels |

and nothing else: no tables, strings, closures, varargs, assignments to globals or fields, native functions (the math
library included), method calls, function values used as values (as arguments, say), several results. A function with any of
those simply stays interpreted. (A loop that is taken over in the middle of a call may also call a function that a local of the
running function holds, and read and assign the locals that closures capture: see "Loops".)

The lowering does not read the specialized state of the arithmetic and comparison nodes (`ArithII`, `ArithNN`, `CmpFF` ...):
they record that a node saw only integers, or numbers, but not which numbers an `ArithNN` met, and a node that was never
evaluated has not specialized at all. It recomputes the types from the operands with the rules the specialized nodes encode
(integer op integer is an integer for `+ - * // %`, anything with a float is a float, `/` and `^` are floats, a comparison is a
boolean): the types of the parameters come from the arguments of the call, constants and the results of calls follow. A
variable, parameter or result that gets an integer in one place and a float in another (`local s = 0 ... s = s + 0.5`) is a
**number of either kind** (`n` in `tier_state`, as in `compiled if->n`): the generated code keeps it as an `nfcr_N`, the value
and a 32-bit flag that says which, and its operators (`nfcr_nadd`, `nfcr_nlt` ...) do what the interpreter's do on two numbers: an
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
  the unit. A tail call does not count, as in the interpreter (`call_closure` reuses the frame of `return f(...)`), so a self
  tail call is compiled as a jump: the arguments go into temporaries first (they read the parameters that are about to change),
  the parameters take them, and the body starts again after the depth was counted. A tail call of another instance of the unit with the
  same result type (another function, or the same one with other argument types) is a **jump through the context**: the arguments go
  into `cx->targ` as words, `cx->tgt` names the callee, the depth is given back and the function returns. The wrapper `nfct_cN` that made
  the call which entered the chain runs the callee (`nfct_dR` switches on the index), and so on until a function returns normally, so
  the C stack stays flat and the depth is the one of the entry (the callee counts its own entry, as the interpreter's frame reuse does).
  A unit with such jumps calls every instance through its wrapper; a unit without them calls the instances directly (`#define`). A tail
  call with another result type is an ordinary call. Only a tail call written `return f(...)` is one: `return (f(...))` is a
  call that counts (the view of the tier keeps the two apart, `TierView::tail`, as `ReturnNode` does).

- **Assigned upvalues are copied in and out.** A kernel may assign an upvalue that holds a number or a boolean. The generated code
  works on a copy of it (the free variables are two words each in the array the engine fills at entry: the value, and for a number
  of either kind its kind), later reads in the same run, also in the other functions of the unit, see the copy, and the engine
  writes the copies back to the upvalues when the run has ended without being abandoned. A run that is abandoned wrote nothing,
  and the interpreter then makes the same assignments one by one up to the same error. That is only right while no other way into
  the same variable is used during the run, so the entry guard also checks, for every cell the unit reaches and assigns, that it is
  reached in exactly one place (two upvalues of two functions of the unit that are one variable, or the captured local of a loop's
  frame that a function of the unit has as an upvalue, are a guard that fails, `tier_guard_misses`; the call is interpreted). An
  upvalue that is assigned has the type it has at entry, widened to "a number of either kind" if the code assigns the other kind of
  number to it (`n = n + 0.5` on an integer); an assignment of a boolean to a number, or of a number to a boolean, is not compiled.

What the tier does not promise: timings; *when* the collector runs (compiled code has no safe points, so a program that watches
`collectgarbage("count")` sees other numbers); and the **sign of a NaN**, which `print` shows (`nan` or `-nan`). The interpreter's
operations make the processor's NaN; the front end folds `0.0 / 0.0` to a positive one, so an operation on two literals goes
through a call the compilers cannot see through (checked in `tier.cpp`), but nothing else was done about a C compiler that folds
a NaN-making operation it can follow through locals (not seen with gcc here). On a target where the C compiler fuses a multiplication
and an addition (aarch64, `__aarch64__` / `__FP_FAST_FMA`) the last bit of a float result could differ, and the tier does not compile
float kernels there: that code is untested, there is no such host in the tests. What can be checked without one is below.

**The fused multiply-add guard (`nfcast_tier.cpp`), checked without an aarch64 host.** Here there is no aarch64 gcc and no qemu;
clang 18 targets aarch64 and writes its assembly. The sample is the generated C of `kone(a,b,c) = ((a) * (b)) + (c)` (from
`nfcxx --emit-c`), with the product in a local in a second function, through each back end:
- **QBE** (cproc, then the QBE IL, then `qbe -t arm64` or `-t amd64_sysv`): never fused. cproc emits no fused operation, and QBE's
  arm64 and amd64 code generators contain none (the sources have no `fmadd`/`fmsub`); the aarch64 output is `fmul` then `fadd`.
- **gcc** (`gcc -O2 -fwrapv -fno-strict-aliasing`, which is what the gcc back end runs, with no `-std`, so GNU mode and
  `-ffp-contract=fast`): fused when the target has the instruction, which aarch64 always does. The middle end fuses across
  statements too. Checked on x86 with `-mfma` as a stand-in (the same middle-end decision): GNU mode gives `vfmadd132sd` and
  `vfmsub132sd` for all three shapes; `-std=gnu17 -ffp-contract=off` and `-std=c11` give none; without `-mfma` (the driver never
  passes it) there is no fusion on x86.
- **clang** `--target=aarch64-linux-gnu -O2`: `fmadd` for the single expression, `fnmsub` for `a*b - c`, and the product in a local
  is not fused (clang's default is contraction within an expression). This is clang's behaviour, not gcc's.
- **The shared helpers do not prevent it.** Generated code writes `+ - * /` on doubles as C operators, and the interpreter's
  float `+ - * /` are its own `ar_nn` in `nfcast_nodes.cpp`. The `nfcr_*` helpers cover comparisons, `fmod`, `floor(a / b)`,
  `pow` and the arithmetic of a numeric `for`, not the four operators. The interpreter does one operation per node, with the
  operands reached through virtual `eval` calls, so no compiler can fuse across two of its nodes (a structural argument: the
  aarch64 object of `nfcast_nodes.cpp` could not be made, as there is no aarch64 sysroot).

Decision: the guard stays as it is. The QBE back end, which is the default, does not contract, so the refusal is stricter than
needed there; the gcc back end does, and nothing here can show the narrowed guard is right on aarch64. The `__FP_FAST_FMA` and
`__ARM_FEATURE_FMA` clauses test the flags of the tier's own build, not those of the generated code (no `-mfma` is passed to it),
so they are conservative. Follow-up when an aarch64 host exists: refuse only for the gcc back end (or give the gcc compile of
the generated code `-ffp-contract=off`, which would also change the C++ the gcc back end compiles), then run `tests/ast/run.sh`
there with the float cases.

### Loops: on-stack replacement

A function that is called once and runs a hot loop is not helped by compiling the function: the call is over before the code is
there. The loops of the main chunk, which is a vararg function and is never a kernel, are the same case. So a loop (`while`,
`repeat` or numeric `for`) is also compiled by itself. Every loop node has a counter of its iterations (`TierOptions::loop_threshold`,
50000; separate from the counter of the function it is in). When it is reached, the loop is lowered like a kernel with the same
rules for its body, as the first function of a unit, and built (the same cache, the same driver, `Sync` or `Async`). Compiled
code takes the loop over **at the top of an iteration**: after one has ended, or, once the loop is compiled, at the entry of the
loop (a function called again, an inner loop run again). Nothing is needed of the part of the function outside the loop.

- **What is handed over.** The locals the loop reads or assigns and does not declare (found while the loop is lowered, at most 24) go
  in by value, with the types they have in the frame at that moment (a version per combination of types, up to four per loop). Their
  values come back, with the kinds they ended with, when the loop has ended, and are stored in the frame; the other locals of the
  function, and the ones the loop declares, are not touched. A local that a closure captures (it lives in a cell) is handed over
  through its cell. A `return` from the loop writes them back too, before the function returns: a closure that outlives the call may
  hold the cell of one. The state of a `for` loop is passed too: the next value of the variable and the count of the integer loop, or the
  variable, the limit and the step of the float loop; the header of the `for` (which has run) is not lowered, so it may be anything,
  `#t` or a call of a native function. The test of a `while` is the first thing the compiled loop runs, and a `repeat` starts at its
  body.
- **What it may contain.** What a kernel may, and a `return` of a number or a boolean (or of nothing) from the function the loop is in.
  A callee may also be a local of the running function (`local function sq`), checked like an upvalue or a global at every entry.
- **Soundness.** As for a kernel: the compiled loop has no side effects until it ends (it works on copies of the locals and of the
  assigned upvalues), so whatever it assumed and finds untrue is handled by abandoning the run, and **the interpreter goes on from the
  same point**: the state at the top of the iteration that was handed over, with nothing changed, which is the state the interpreter
  was in. Errors, their messages, positions and tracebacks are the interpreter's, because it is the interpreter that finds them. The
  price of that is that the work of an abandoned run is done again; a loop that is abandoned is not tried again before it is entered
  anew, and one that is abandoned in more than a quarter of its runs, after eight, is given up. The entry guards (the callees, the types
  of the free variables, the types of the locals, the depth and the stack, and the cells) are checked at every takeover.
  A loop that was not lowerable is looked at again at three growing gaps, then left alone for good.
- **What is not covered.** Loops whose bodies are not kernels (a table, a string, a closure, a native call, a global write); a
  `for ... in` loop (`pairs`, `ipairs`, any iterator: nothing is compiled for them, and a `pairs` loop's body that calls such loops
  is ordinary interpreted code around a compiled inner loop); a live local that is nil, a table, a string or a function at the time
  (a loop is not compiled for locals declared without a value, e.g. `local last` assigned in the loop); goto; more than 24 live
  locals; a loop inside an inlined body. A loop taken over from the middle is taken over only at the top of an iteration, not
  inside the body of an iteration.

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
`tier_guard_misses` (an argument or a binding the code did not assume) and `tier_aborts` (a run abandoned half way). For loops:
`tier_osr_runs` (loops, or what remained of them, that native code ran to the end or to a `return`), `tier_osr_bailouts` (times a loop
that has compiled code went on in the interpreter: a guard failed or a run was abandoned) and `tier_osr_ineligible` (loops that
cannot be compiled, counted once). `TierOptions::osr` (default true; `NFCAST_TIER_OSR=0`) turns the loops off;
`State::tier_loops(fn)` says what became of the loops of a function (`line 3: compiled ii; line 9: ineligible: why`).
The shared counters (`tier_compiled`, `tier_compiles`, `tier_cache_hits`, `tier_failed`) count the versions of loops too.

### Limits

- On-stack replacement takes a loop over only at the top of an iteration and only for the shapes above; the list of what it does
  not cover is in "Loops". A hot loop whose body has a table access or a native call still runs entirely in the interpreter.
- Only the shapes above. In particular calls of native functions (`math.sqrt`, `math.floor`), tables and function values stay
  interpreted.
- Types are static: a variable is an integer, a float, a boolean or a number of either kind for the whole function; one that is a
  boolean and a number, or a function called with a string or a table, is not compiled. A number of either kind carries its flag and
  tests it in every operation, so it is slower than a plain `double`. At most four versions
  per function, 12 parameters, 24 functions in a unit, 48 typed instances.
- A toolchain finding, kept in `nfcast_tier_rt.h` as a comment: the QBE back end miscompiled a struct that has a 4-byte member next to
  padding and is copied by value, as the generated code copies an `nfcr_N`: the branch on the member tested the padding half of the
  word (a float came back as its integer part). It was found by comparing a small accumulator with real Lua. Root cause: amd64 isel
  of QBE (fixed by `scripts/qbe-wflag.patch`, test `tests/cases/qbe_wflag_padding.cpp`, report `docs/notes/qbe-wflag.md`). With the
  patch `nfcr_N`'s flag is a 32-bit `int` again; with a QBE built without it, 4 checks of `tier.cpp` and `tier_kernels.lua` fail on
  qbe, so re-run `scripts/setup-qbe.sh` after pulling.
- A kernel that fails often costs the failed run plus the interpreter's run until it is given up.
- **A tail call between functions with results of different types is still a C call.** The jump above needs the callee to return the
  same type as the caller (`return g(x)` in `f` where `g` returns a float and `f` an integer is not one). Such a recursion deeper than
  `State::max_depth` (1500) abandons its run at the limit, and the interpreter goes on in constant stack; each tail call that the
  interpreter makes is offered to the compiled version again, which runs up to the limit and is abandoned, and a version that aborts in
  more than a quarter of its runs, after eight, is given up. A given-up version is then found by its argument types without building a
  signature (`try_versions` sets `given_up`); before that, every interpreted call of such a function built a signature vector and looked
  it up, which was about two thirds of the cost of the mutual recursion below (not a native cost: `tier_calls` stays at zero there).
- **Mutual tail recursion** (`is_even` / `is_odd` written as `return is_odd(n - 1)`, same result type) is a jump, and was measured as
  such (below). Before the change it was a C call per step: the native runs stopped at the depth limit, eight of them per version,
  and the interpreter paid for each attempt and for each signature lookup on the way.
- Entering native code from the interpreter costs about as much as a call of a small function in the interpreter (the checks, a
  `setjmp`): a tiny kernel called from a loop in the interpreter gains little (ten million calls of
  `x * 2 + 1`, 0.54 s instead of 0.53 s); what gains is a kernel with a loop or a recursion inside, which runs inside one entry.
- A `for` loop with a NaN start or limit does what Lua's `forprep` does (the body of a float loop runs once; `nfcr_forlimit` takes a
  NaN limit as Lua does), in the generated code as in the interpreter.
- It needs POSIX (`fork`, `dlopen`), the nfcxx driver and the `lib/ast` directory next to it at run time.

## Verification

- `tests/ast/cases/*.lua`: sixteen programs (arithmetic and number formatting, strings and patterns, tables, closures,
  metatables, errors and their messages, control flow, algorithms, garbage-heavy code, proper tail calls (`tail_calls`), numeric
  kernels, `tier_kernels`, `tier_osr`: loops taken over in the middle of a call (see below), and `tail_loop`: a million-deep self
  tail recursion as a kernel (integer and float accumulators, arguments that swap, a tail call that changes a type, a loop that calls
  one each time), depth counted only by the calls that are not tail calls, mutual recursion (a million steps, and a deep chain whose
  last step divides by zero, and a chain with calls that count depth past the limit, compared with the interpreter's `stack overflow`),
  and the errors inside deep tail recursions) and, for the inlining, thirteen more named
  `inline_*` (argument adjustment and the order of evaluation; parameter substitution (`inline_subst`: locals, constants and
  expressions as arguments, a parameter assigned, the same local twice, side effects between pure arguments, a boxed local and
  an upvalue the callee changes, error messages that name the callee's parameter, chains four deep, recursion, methods, a site
  that meets another function afterwards, fewer and more arguments than parameters); loops and multiple assignment
  (`inline_loops`: numeric, float, while, repeat, generic and nested loops, `break`, `return` from inside, errors with their
  lines and levels inside loops, swaps and multiple assignment to locals, fields, indexes, upvalues and globals, loops that
  allocate, recursion through a loop, methods); sites that meet other functions (`inline_retry`: long runs of one function and
  then another, alternation at every call, a native or `__call` in between, methods replaced in the class or shadowed with
  arguments, extra arguments that the first callee does not read and the next does); errors raised inside inlined bodies: message, position, variable
  names, `error` levels 0 to 3, error values that are not strings, `pcall` inside and outside, a callee from another chunk, natives
  called with bad arguments; a callee that is assigned again after its site was rewritten, a closure of the same function with
  other upvalues, a native or a `__call` table or nil in its place, methods replaced in the class or shadowed in the instance;
  upvalues read and written; arguments of every type, with metamethods; recursion, mutual recursion, runaway recursion and a deep
  legal one; chains of calls deeper than the inliner goes; methods, inheritance, receivers of different classes at one site;
  bodies with locals, `if` chains, assignments, no result and several; allocation for the collector). Each `.out` file next to
  them is the output of a real Lua 5.4.9 (`tests/ast/regen.sh`, built from the pin of `setup-poly-lua.sh`), and
  `tests/ast/run.sh` requires the same stdout from nfcast on both back ends, with inlining as it is by default, with a site
  rewritten as soon as it is used twice (`NFCAST_INLINE_WARM=1`) and with inlining off (`NFCAST_INLINE=0`); and with the tier on
  and every function compiled at its first call (`NFCAST_TIER=sync`, `NFCAST_TIER_THRESHOLD=1`), normally and with early
  inlining, and with the tier compiling in the background (`NFCAST_TIER=async`): 29 programs, 6 runs each, per back end. The
  collector's forced stress (`NFCAST_GC_STRESS=1`) is no longer in this script (it is slow; `engine.cpp` and `tier.cpp` still run
  it on their own checks). Two of the first programs had a syntax error in my
  first version and compared equal because *both* implementations refused them: the check also requires that the reference run
  succeeds (`regen.sh` and the helper that wrote the `inline_*` outputs refuse a reference that fails or prints to stderr). Thirteen of the 29 programs are `inline_*`.
- `tests/ast/engine.cpp`: 194 checks through the C++ API (13 of them for the operators that read their operands in place) (the specialization counters, the collector, host objects, errors, the
  state of the interpreter after errors, pins) and, for the inlining, with `State::stats`: a loop of calls rewrites its site once
  and runs the rest inlined (97 of 100 calls with the default count, 98 with `inline_warm = 1`), a state with inlining off or
  `inline_warm = 0` inlines nothing; the guard fails once when the global is assigned again (to another function: the site is inlined again for it and runs every
  call inlined from then on; to a native or nil: the site is the generic call for good); a site that alternates between two
  functions at 200 calls is rewritten a bounded number of times (four to seven rewrites in all, not a hundred); closures of one function with other upvalues do not fail it; three sites
  that send integers, floats and strings to one helper take about 100 slow paths with inlining and at least 295 without
  (the shared tree goes generic); methods (a getter, an instance that shadows it); numeric, `while`, `repeat` and generic loops
  with `break` and multiple assignment (locals, a field and an index) are inlined, varargs are declined and counted, closures
  too, a body over the size limit too; `State::stats.inline_substituted` counts the substituted arguments (a local and a
  constant yes; an assigned parameter, a local with a loop in the body, a boxed local and a global no) and the errors raised through
  a substituted parameter carry its name and the callee's line; with the tier on, a callee with a loop is declined and a
  loop-free one is inlined; a chunk with 3500 sites of a three-node function
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
  types change; since the second inlining the helpers and methods also have loops (numeric, float, `while`, `repeat`, `break`,
  `return` from inside, `ipairs`), multiple assignment (swapped parameters, fields, an upvalue), assigned parameters, and some
  expressions call through a list of helpers indexed by the argument tuple, so the callee of a site changes (the guard, the
  retries); the helper programs run with the default count, with `NFCAST_INLINE_WARM=1` and with inlining off. Equal output
  to the reference, error messages and their positions included, after fixing what it found: float modulo with two negative
  operands (`-2 % -2^63`), string operands of bitwise operators (an error in 5.4), and where Lua's error messages carry a variable
  name. 300 seeds of each kind (the helper kind three times) ran without a mismatch for the inlining. After the second inlining 200 seeds of each kind ran without a mismatch on the gcc back end (the first run of the new generator found 12 programs that
  differed, all one bug: the arguments of a call that the first callee did not read, extra ones that were never stored, were not
  put back when the site met a callee that reads them).
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
- Mutation checks of the second inlining (substitution, plans, loops, retries), on scratch copies against the engine test and
  the inline programs (default count and `NFCAST_INLINE_WARM=1`, collector stress on the second): 16 mutants, 13 caught. Caught:
  the parameter-written bit not recorded (engine); the values of substituted arguments not put back when the guard fails, for a
  call site and for a method site (`inline_subst`, `inline_retry`, `inline_redefine`, engine; the method one only by an
  `inline_retry` section written for it); the same for extra arguments that were never stored (`inline_retry`, which the fuzzer
  found first: a method site inlined for a one-parameter function and then meeting a two-parameter one read a stale slot); no check
  for a boxed local as an argument (nine programs); substitution in bodies with loops (engine); no cap on the retries
  (engine); the arguments not rooted while a later one is evaluated (`inline_subst`, `inline_types`, `inline_gc`);
  a multiple assignment to a parameter, and an assignment to one, that do not count as writes (engine, `inline_loops`,
  `inline_args`, `inline_stmts`); the `up` count of the substituted node off by one (nearly every inline program); no refusal of
  loops when the tier is on (engine). Survivors, all equivalent: the loop variable and the declarations that do not record a
  write (they cannot be on a parameter's slot, and bodies with loops are never substituted), and the line that sends calls with an
  expanding last argument past the plan (the plan only substitutes arguments that a real call also reads from a slot, and
  `place_args` falls back to `push_args` itself).
- The same inlining with the temporary check `S.cur == &caller` in the frame of an inlined call (the substituted nodes read the
  caller through `prev`), run over all programs in the eight host configurations, the engine test and 100 fuzz seeds of each
  kind: never false. It is removed again; nothing in the engine (no coroutines) makes a frame run with another `S.cur`.
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
- `tests/ast/cases/tier_osr.lua` (its output is a real Lua's, like the others): at threshold 1 every loop is compiled at its first
  iteration boundary and the rest of it runs as native code. Main-chunk loops over integer, float, boolean and either-kind locals
  (a sum that becomes a float only in the loop, one that stays an integer), `while` and `repeat` with `break`, steps and directions,
  float limits, the ends of the integer range, nested loops, kernels called from the loop through upvalues, globals and locals
  (also a local that is a recursive function, so lives in a cell), a global rebound between loops, functions called once with a
  `return` inside the loop (an integer, a float or an either-kind result, no value, a function with two kinds of `return`), the locals
  after the loop and the ones it does not touch, loops that fail half way (`//` and `%` by zero, a bitwise operation on a float, a
  runaway recursion, an error in a callee after an assignment of an upvalue: the message and line are the interpreter's), the line of an
  error after a loop that was taken over, loops that are not kernels, other types of the locals the next time, locals that closures
  capture (integer, float, both kinds, boolean), kernels that assign upvalues (also several at once, both kinds, a boolean, a float
  that is assigned an integer), and one variable reached in two ways while it is assigned. The counters of a run in the four
  configurations: 46 loops taken over, 7 left to the interpreter by a guard or an abandoned run, 10 that cannot be compiled.
- `tests/ast/tier.cpp`: 347 checks of the tier through the C++ API, with the nfcxx driver of the build. The first compile and
  its counters; a float argument to an integer kernel (a bailout, later a second version); recursion; a self tail call as a loop (a
  million deep in one entry with no abandoned run, an error inside it abandoned and then the interpreter's, `return (f(n))` against
  `return f(n)` at the depth limit); mutual tail recursion as jumps (a million deep in one entry, with the counters; an accumulator
  that is a number of either kind passed along the chain; float arguments; an error at the end of a chain, the interpreter's message;
  calls that count depth inside a chain, within and past the limit); mutual recursion; numeric
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
  `State` destroyed while one runs); a host that ignores `SIGCHLD`. The checks above run with the on-stack replacement of loops off
  (`TierOptions::osr = false`), so that what they count is the functions; two sections of their own turn it on. The first: a loop
  of a main chunk or of a function that is called once taken over after 100 iterations (`tier_osr_runs`, no whole function compiled);
  a main chunk with 150 locals (the stack guard must not count its frame: that bug was in the first version, found by the
  program above, not by a check); float loops, loops that count down, a return from inside a loop; 20 programs run with and without
  the tier that must print the same (the locals after the loop, kinds of numbers, wraparound, the ends of the integers, nested
  loops, tables and closures and native calls in the loop, errors in the loop); a division by zero half way (one abandoned run,
  `tier_osr_bailouts == 1`, then the same loop without the error runs); a loop that is abandoned is not tried at every iteration and one
  that always is, is given up (at most 12 bailouts in 40 runs of 100 iterations); another version for other types of the locals; a
  global that changes type; a rebound callee; the option that turns it off; a function whose loop is taken over at its entry the
  second time (a function that is not a kernel as a whole, a call with 0 iterations, one with 1); the collector at every safe
  point; asynchronous compiles (including two chunks with the same loop being built at once, which broke the files of the builds
  before the sequence number); a vararg chunk. The second: kernels that assign upvalues (one, both kinds, several at once,
  an error after assignments, a recursion that assigns, a runaway recursion that assigns, a boolean, a number that becomes a boolean,
  an assigned cell reached by two functions, two counters from one factory, a global assigned by a kernel, which stays interpreted);
  loops over captured locals (through the cell: the loop runs as native code, with the alias of an assigned cell the guard fails and
  the interpreter runs it), local functions as callees (also one that is a cell, one that is another function the next time, one
  assigned in the loop, a number, a native function).
- `tests/ast/fuzz_tier.sh` (by hand): random numeric kernels (`fuzz/gen_kernel.py`: integer, float, boolean and "number of either kind" locals, parameters and results, every
  operator, `if` / `while` / `repeat` / `for`, `break`, upvalues and globals that change type between calls, calls between functions,
  recursion, functions without a result, wrong and missing arguments) run by a real Lua 5.4.9 and by nfcast with every function
  compiled at its first call, output and error messages compared. On the final code: 24 seeds of 10 functions on the gcc back end (321 functions compiled, 1251 calls ran as native code) and 25 seeds on qbe (268 and 1224), no mismatch. It also found two differences between the engine and
  Lua that have nothing to do with the tier (a float `for` loop whose start is NaN runs its body once in Lua and not at all; an
  integer loop with a NaN limit and a negative step counts down to `math.mininteger` in Lua): both are fixed since, and the generator
  only stays away from a computed limit in a loop that counts down (it would run to the smallest integer). Since the on-stack replacement and the assignments of upvalues the generator also makes kernels that
  assign the chunk's upvalues (also two at once) and prints the upvalues and globals after each call, and "segments": functions that are
  not kernels as a whole (they make a table), with locals of the four types, one that a closure captures, a local function, and
  random loops (every kind, with `break` and `return`) that read and assign them, called three times with changing arguments and
  free variables, so that only the loops are compiled. Result: 40 seeds of 8 functions on gcc (488 functions and loops compiled, 1846 calls and 121 loops ran as native code) and 40 on qbe (504; 1845; 473), no mismatch.
  The generator also ends about half of the recursive functions with a tail call of themselves (`return k(d - 1, ...)`, a loop in the
  tier). After that change, `NFCXX_BACKEND=gcc tests/ast/fuzz_tier.sh 15 8 5`: 15 seeds of 8 functions, no mismatch (167 functions and
  loops compiled, 617 calls and 59 loops ran as native code); `NFCXX_BACKEND=qbe` with the same arguments: the same counts and no mismatch.
- The tier test, the engine test and the programs of `tests/ast/cases` with the tier at threshold 1 and the collector stress, under
  AddressSanitizer and UBSan (host g++ for the engine, nfcxx for the generated code): no report (rerun after the on-stack replacement: engine test, tier test with 315 checks, and the tier cases, clean).
- Mutation checks on scratch copies of `nfcast_tier.cpp`: 21 mutants, each breaking one guard or one rule (the check of the callee, of the argument types, of the types of the free variables; the integer `//` by zero left to the interpreter; the depth limit; a `for` step of zero; the exact comparison of an integer with a float, in the generated code and in the shared header, for `<`, `<=` and `==` and for each order of the operands; the order in which a multiple assignment stores; the number type's zero divisor, conversion for bitwise operators, `>`, widening and result kind; the instances that widened types leave behind). The tier test fails for 20 of them (one by running into its `alarm`), and the golden kernels program differs for 13; the mutant of the equality of an integer and a float of either kind passed at first, which is why the test now has a grid of every comparison around 2^53 and 2^63 on such numbers. The one it does not notice: the hoisting of operands that can fail into temporaries is not needed by this toolchain, which evaluates operands left to right, so removing it changes nothing here; the check that would hang without it only has teeth on a C compiler that evaluates the other way.
- Mutation checks of the on-stack replacement and of the assignments of upvalues, on scratch copies of `nfcast_tier.cpp` (and `nfcast_nodes.cpp`),
  20 mutants, each against `tier_osr.lua` and `tier_kernels.lua` at threshold 1 (with and without the collector stress) or the checks of
  `tier.cpp`: the types of the live locals not compared when a version is chosen; the check that an assigned cell is reached in one
  place only; the copy-back of the assigned upvalues; the kind of a number of either kind written back to a local, and the kind with
  which a float upvalue comes in; an abandoned run treated as a success; the count of a `for` loop off by one, and the next value of a
  float loop not advanced (in `nfcast_nodes.cpp`); the returned value dropped; a `return` that does not write the locals back; a captured
  local written back to the frame instead of its cell; a callee that is not checked; a callee in a cell not looked through (the
  program prints the same, only a count of `tier.cpp` notices); the types of the live locals not looked at; the order in which a multiple
  assignment stores to an upvalue; a loop that is abandoned and tried again at every iteration, and one whose guard keeps failing and
  is never given up; the stack guard counting the frame of the loop's own function; two builds of the same code in one `State` sharing their
  files. Several passed at first and led to a test: `tier_osr.lua` had no loop whose numbers become floats only late (the
  type decided at the handover is the integer one), none entered twice with other types of the locals in a function that is not
  compiled as a whole (the whole-function version took the later calls), no upvalue that is a float at entry and an integer later
  (the first call overwrote the garbage), no multiple assignment of one upvalue twice, none that returns from a loop while a closure holds
  the cell (found by review, not by a mutant: the first version wrote the locals back only when the loop ended, not at a `return`), and `tier.cpp` did not check `tier_failed` after the asynchronous section. The one a program cannot see (a callee in a cell
  not looked through just makes the loop run in the interpreter) is a count in `tier.cpp`.
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

`RUNS=3 tests/ast/bench.sh host gcc qbe` (programs in `tests/ast/bench/`, best of 3 runs, seconds; the machine was shared with other
jobs and its load changed during the runs, so times move by 10% to 30% between runs, and the "off" column of the same program
differed by that much between two runs of an unchanged engine; nothing asserts on them): `helpers` is 5 million iterations of a loop
calling small math helpers and predicates, a two-level call (`dist2` calls `sq` twice) and table accessors; `getters` is 3 million
iterations of method calls on objects with a metatable (`a:getx()`, `a:dot(b)` calling two getters, a setter); `fib` is `fib(32)`.
Times of the second inlining (parameters read where they are, arguments placed without virtual calls, loops and multiple
assignment accepted, sites inlined again after a guard failure; "before" is the engine of the commit it was developed on, "off" is
`NFCAST_INLINE=0` of the same engine):

| Target | Program | before | after | off (after) | before / after |
| --- | --- | --- | --- | --- | --- |
| host g++ -O2 | `helpers` | 2.16 | 2.19 | 3.15 (noisy; 2.5 to 3.2 in other runs) | 0.99x |
| | `getters` | 1.89 | 1.97 | 2.52 | 0.96x |
| | `fib` | 0.46 | 0.44 | 0.48 | 1.05x |
| nfcxx, gcc back end | `helpers` | 3.60 | 3.36 | 5.81 | 1.07x |
| | `getters` | 2.96 | 2.71 | 4.25 | 1.09x |
| | `fib` | 0.88 | 0.93 | 0.98 | 0.95x |
| nfcxx, qbe back end | `helpers` | 6.75 | 6.38 | 9.04 | 1.06x |
| | `getters` | 4.99 | 4.76 | 7.37 | 1.05x |
| | `fib` | 1.47 | 1.51 | 1.61 | 0.97x |

Those wall times cannot show a difference of 5% (the same engine measured twice differs by more), so the honest summary is "no
slower, a little faster on the back ends"; the instruction counts below are the measurement. The same reference Lua 5.4.9 takes
1.2 to 1.3 s on `helpers`, 1.2 s on `getters` and 0.16 s on `fib` on this machine, so the loops that call small functions are still
about 1.7x (`helpers`) to 1.6x (`getters`) slower than Lua with the host compiler and inlining on, and `fib` 3x.

Instructions, which do not depend on the load of the machine (callgrind, the host build, 100 thousand iterations of `helpers`,
60 thousand of `getters`, `fib(24)`; before = the engine before this change, after = this one; "off" runs the same engine with
`NFCAST_INLINE=0`):

| Program | before, inlining | before, off | after, inlining | after, off | saving before | saving after |
| --- | --- | --- | --- | --- | --- | --- |
| `helpers` | 461.2 M | 568.4 M | 430.4 M | 570.2 M | -18.9% | -24.5% |
| `getters` | 437.8 M | 517.2 M | 429.3 M | 518.8 M | -15.4% | -17.3% |
| `fib(24)` | 89.1 M | 90.1 M | 88.1 M | 90.4 M | -1.1% | -2.5% |

So the gain over the first inlining is 6.7% of the instructions of `helpers` and 2% of `getters`: the saving relative to no
inlining went from 15% to 19% up to 17% to 25%, not to the several times that a compiler's inliner gets, because the nodes of the
body, not the call, are most of what is left. What was done and what it bought, from the callgrind
profile of a loop of `sq(i % 100)` and `clamp(i % 200, 20, 150)` (400 thousand inlined calls, 259.1 M instructions before):
placing the arguments by a plan instead of `push_args` and the argument nodes (no virtual call or loop per pure argument; the
callee expression when it is a local or an upvalue is read directly): -7.2 M instructions (259.1 to 251.9 M); substituting the
parameters that are locals or constants on top: -7.4 M (to 244.5 M); that is 36 instructions per call out of roughly 600 per
call including the loop around it (an inlined call still costs about 100 instructions: the frame, the guard, the results, and the nodes of
the body, which are unchanged: a substituted parameter is a virtual call to `SubstLocal::eval` instead of one to `LocalNode::eval`,
so the read costs the same and what is saved is the copy and the evaluation at the call). The operator nodes that take those
operands are the next step, done in the section below. What would save more: for the method
benchmark a cache for methods inherited through `__index` (`getters` spends about a quarter of its instructions in
`find_str` / `index_slow` looking the method up in the instance, missing, and then in the class, which inlining does not touch).
That is the honest size of the gain for a tree walker that inlines by cloning: about 20% to 25% of the instructions in a loop made of small
calls, and 1% to 3% for `fib`, where the unrolled level contains the same two calls it replaced. The tier does not use the clones
(see "What the tier does with it"): it compiles whole kernels, and the inlining helps what stays interpreted.

### Operators that read their operands in place

The arithmetic and comparison nodes (`ArithII`, `ArithNN`, `CmpII`, `CmpFF` in `nfcast_nodes.cpp`) are instantiated for the
shape of each operand: `kLocal` (a local of the running frame that is not boxed, or a substituted parameter that reads an outer
frame, `SubstLocal`), `kConst` (a constant or `SubstConst`), or `kGen` (anything else, evaluated through its node as before). A
binary operation of two leaves therefore reads its operands itself, with no virtual call to them, and makes one virtual call (its
own `eval`) instead of four. The shape is taken when the node is specialized, after the function is complete (a boxed local is
then known), by `respec_shape`; the operand nodes stay the parents, so the generic path, the messages of errors (`describe`) and
the tier's view (`ArithBase`, `CmpBase` with `l_`, `r_`) are unchanged. The type guards and the deopts are the ones the nodes had.
An `Uninit` node and the generic `ArithGen` / `CmpGen` evaluate their operands through the nodes, as before. The 25 operator
templates (10 integer, 7 number, 4 integer and 4 float comparisons) times 9 shapes make 225 classes; the build time this adds was
not measured. `EqNode` (`==`, `~=`) is not specialized.

Tried first and dropped: reading the operand through a run-time switch on its kind inside the existing nodes. That removed the
leaf calls (the leaf bodies went from about 28 M to 6 M instructions in `helpers`) but the switch cost more than the calls it
replaced, and the whole went up by 15 M. The shapes are compile-time, which is why the templates.

Instructions (callgrind, host g++ -O2, the same programs and sizes as the table above: `helpers` 100 thousand iterations,
`getters` 60 thousand, `fib(24)`; "before" is the commit this change was made on, "after" this change; "off" is `NFCAST_INLINE=0`):

| Program | before, inlining | before, off | after, inlining | after, off | change, inlining | change, off |
| --- | --- | --- | --- | --- | --- | --- |
| `helpers` | 433.5 M | 614.6 M | 392.6 M | 574.7 M | -9.4% | -6.5% |
| `getters` | 431.1 M | 545.5 M | 427.2 M | 541.6 M | -0.9% | -0.7% |
| `fib(24)` | 93.3 M | 97.7 M | 84.4 M | 88.8 M | -9.6% | -9.1% |

The saving of the inlining itself (on against off, same engine) went from 29.5% to 31.7% for `helpers`, from 21.0% to 21.1% for
`getters`, and from 4.5% to 4.9% for `fib`. `getters` gains nothing: its time is method lookup (`find_str`, `index_slow`), not
arithmetic. The gain on `helpers` is above the 3% that would have justified the complexity.

The wall times of this change were not measured (nothing asserts on them, and the machine's load moves them by more than the gain).
The same test programs print the same output with inlining on, early and off (`tests/ast/bench.sh` checks that), and a Lua program
that exercises every operator over every pair of values (integers, floats, strings, nil, booleans, tables with metamethods) with
its operands as locals, constants, inlined parameters and boxed locals prints the same as the commit before, and as Lua 5.4.

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
| `osr`: loops of the main chunk and of a function called once that is not a kernel | qbe | 6.74 | 1.14 | 0.28 | 24x |
| `osr` | gcc | 2.90 | 0.91 | 0.12 | 24x |

"Cache empty" includes the compile (a few tenths of a second per function; the programs have one or two functions); "cache warm" is
every run after the first one of a program, when the shared object is only loaded. The last column is the interpreter's time over the
warm time; the warm times of a few hundredths of a second include starting the process and loading the object, so the quotients are
rough. The programs: `fib(32)`; ten calls of a function
that runs a loop of three million iterations of `s + i * 3 % 7` (`intloop`); the same shape with a sum that starts as the integer 0
and becomes a float, a number of either kind (`accum`); the Mandelbrot iteration count over a 200 by 200 grid (a `while` loop and a
multiple assignment on floats; 1.5 million iterations, so little time to gain on); twenty integrations of 500000 steps that call
another kernel through an upvalue and read a numeric upvalue.

`osr` (new, `tests/ast/bench/osr.lua`) is the case the other programs are not: a loop of 30 million iterations of `s + i % 7` and one of
10 million iterations of a float recurrence in the main chunk, and a loop of 30 million iterations in a function that is called once and
is not a kernel as a whole (it makes a table). The interpreter takes the whole run; with the tier each loop is compiled at its first
iteration boundary (here: threshold 1; at the default 50000 iterations the loop runs 50000 iterations in the interpreter first) and
taken over, the table and the `print`s stay in the interpreter. The figures of the other programs did not change within the noise of the
machine (the tier off, the same engine without and with the new hooks: `intloop` 1.28 s against 1.33 s, `accum` 0.98 against 0.99, `fib`
0.87 against 0.89, `integrate` 1.23 against 1.22, `mandel` 0.31 against 0.25, best of three, host gcc back end). With the cache empty
and the threshold at 1, a program whose main chunk calls kernels from loops pays for the compile of the loops too (`mandel`: 0.25 s
interpreted, 0.79 s with an empty cache, 0.02 s with the cache warm: its three loops of the main chunk are each a compile of about 0.2 s); the
default threshold avoids that for loops that do not run long.

A **self tail recursion** is a loop in the native code (see "Soundness", Depth). The program `local function loop(n, acc) if n == 0 then
return acc end return loop(n - 1, acc + 1) end print(loop(1000000, 0)) print(loop(3000000, 0.5))`, qbe, warm cache, best of three on a
machine that other jobs were loading (a factor of 1.5 is the noise): the interpreter 0.89 s; the tier before the change 2.8 s at
threshold 1 and 3.8 s at the default threshold, where every compiled run went up to the depth limit, was abandoned, and the
interpreter started it again, eight times per version, before the version was given up; after the change 0.039 s at threshold 1 and
0.13 s at the default threshold, where the first 2000 calls of each version run in the interpreter and the rest run natively in one
entry, with no abandoned run.

**Mutual tail recursion** is a jump too (see "Soundness", Depth). The program `is_even(1000000)` and `is_odd(1000001)` (`return is_odd(n - 1)`
and `return is_even(n - 1)`, each returning a boolean), with the tier at its default threshold and at threshold 1, best of three, warm
cache. The machine was loaded and the interpreter's own time moved between the two sessions (0.66 s and 1.05 s on qbe), so the rows compare
the drivers of one session with each other: the driver of the commit before the change (`tests/ast/driver.cpp` built from `origin/main`)
and the one after it, run one after the other:

| back end | driver | interpreter | tier, default threshold | tier, threshold 1 |
| --- | --- | --- | --- | --- |
| qbe | before | 1.05 s | 2.42 s | 2.20 s |
| qbe | after | 0.66 s | 0.07 s | 0.06 s |
| gcc | before | 0.38 s | 1.48 s | 1.20 s |
| gcc | after | 0.53 s | 0.03 s | 0.03 s |

Before the change the tier was 2.3 times slower than the interpreter on qbe and 3.9 on gcc. After it, the two calls run natively in one
entry each (`tier_calls` counts them, and nothing is abandoned), and the program is 9 to 18 times faster than the interpreter. The
other benchmarks of `tests/ast/bench` are where they were within the noise (`fib` and `mandel` on both back ends, before and after).
Earlier, when the change was first measured on the same machine at a higher load, the interpreter was 0.68 s and the tier 1.44 s (qbe) and
0.25 s and 0.81 s (gcc). The fix (`tier_dispatch`'s given-up path, and the jumps) was chosen over making such groups interpreted again:
refusing to compile them would keep the interpreter's speed, and the jumps give the native speed for the same code, which is the larger gain.

What the tier does not help: a work that is not a kernel (tables, strings, native functions, closures in the hot part), and a loop whose
iterations are cheap enough that the compile of 0.2 to 0.3 s is not paid back. A tiny kernel called from an interpreted loop
gains little when the loop stays interpreted (ten million calls of `x * 2 + 1` from a loop at the top level, with the on-stack replacement
off: 0.53 s to 0.54 s on the host compiler); with the loop taken over too the whole thing is native: the same program with the default
thresholds, gcc back end, 0.72 s interpreted, 0.36 s the first time (it includes the compile) and 0.05 s with the cache warm. With the tier off the
engine runs as fast as before the hooks: measured with the host g++ -O2, best of three, with the tier off
against the engine of the milestone-1 commit: `fib(32)` (with `fib(20)` and `fib(27)` before it) 0.44 s against 0.46 s; 5 million
calls of a function that reads a table field, so is not a kernel, and `fib(30)`, 0.44 s against 0.42 s; the loop of ten million calls of a
tiny kernel 0.53 to 0.61 s against 0.52 to 0.58 s over three repetitions; `intloop` 0.93 against 0.99, `mandel` 0.23 against 0.25,
`integrate` 1.02 against 1.08, `accum` 0.67 against 0.70: no difference beyond the noise of a machine that other jobs were using (about
10%). A `State` without a tier pays one pointer test per call and per loop iteration.
