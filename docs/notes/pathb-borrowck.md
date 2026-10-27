# Local lifetime checking on Path B IR

`scripts/pathb-borrowck.rb` implements the first part of the
[borrow-checker plan](borrowck-plan.md). It checks annotated Path B IR independently of code generation.
The existing C++ frontend emits the required facts with `NFCXX_PATHB_BORROW=1`:

```sh
NFCXX_PATHB_BORROW=1 scripts/pathb-dump --ir example.cpp > example.ir
scripts/mrb scripts/pathb-borrowck.rb example.ir
```

This command explicitly opts the supplied module into analysis. It checks every function, without
changing how the regular compiler builds the program. A successful result means only that the
implemented local checks passed on the supported subset, not full Rust or C++ memory safety.

## Shared facts and analysis

The initial fact vocabulary is already accepted by the QBE emitter as metadata:

```text
(decl $"x" val)          local storage starts, initially uninitialized
(decl $"r" ref)          reference storage starts; pointers retain the same provenance tracking
(decl %0 ref)           reference parameter; caller-owned storage
(decl $"tmp" temp)       a compiler temporary's storage starts, initially uninitialized
(scope-end $"x")         local storage lifetime ends
(rref-arg $"x")          C++ rvalue-reference argument; requires future move contracts
```

The C++ frontend also prints facts for storage that no declaration names:

- Temporaries made by EDG's lowering, plus the printer's own aggregate temporaries. A temporary
  used in exactly one full expression gets `(decl $"tmp" temp)` before that expression and
  `(scope-end $"tmp")` after its value is used. A pointer to it therefore cannot outlive the
  full expression unnoticed.
- Temporaries that carry a value across statements, such as a returned aggregate or a range-based
  for's range and iterators. These get one `decl` at function entry and a `scope-end` at each
  exit. This is decided at the end of each function, because the printer cannot know earlier
  how many full expressions use a temporary.
- A named local that no declaration statement introduces, such as a range-based for's variable,
  which the lowering initializes by assignment. It is declared at its first use and ends with
  that block.
- A variable-length array. EDG's lowering makes it an ordinary local pointer to storage from
  `__vla_alloc`, so it gets the facts of any local. Calls to `__vla_alloc` have no summary, so the
  function is still refused.
- An unnamed parameter. Unnamed parameters all print as `"tmp"` while their slots are `tmp`,
  `tmp.1`, and so on. The checker pairs a parameter with the slot of its name, so a slot of another
  name gets `(decl $"tmp.1" val)` before the parameter is stored into it.

Exception-handling bookkeeping temporaries get the same treatment, which is conservative: a value
or address carried to a later statement reads as uninitialized or out of scope, never as valid.
Label depths for jumps count only declaration statements, so a jump can end a first-use local
early. That is also conservative. With the flag unset, output is byte-identical.

### EDG's exception-handling stack

EDG lowers C++ exception handling to a linked stack of frames. Each frame is a local temporary.
A function pushes a frame by saving the global `@"__curr_eh_stack_entry"` in it and storing the
frame's address in the global. It pops the frame by storing the saved value back. The scalar
global `@"__eh_curr_region"` is saved and restored the same way.

The runtime reads frames only while unwinding. A call of a `may-throw` callee can start an unwind
while a frame is pushed. The unwind is not a path the checker follows (see "Throwing calls" below),
so the stack top is still tracked as a value on the normal paths:

- A load of `@"__curr_eh_stack_entry"` yields what was last stored there, initially the caller's
  frames.
- A store of a frame address replaces it. A store of unknown provenance is refused.
- At every `return` and function exit the top must be the caller's frames again. A frame still
  pushed, or one whose scope ended while pushed, reports `eh-frame-not-popped`.

Stores into other external memory, such as globals, are allowed when the stored value is a
scalar or an external pointer. Only a local address can escape that way, and that is still
refused. A verified summary still reports any such access as `contract-not-closed`. Writes to
`@"__eh_curr_region"`, the region counter that tells the runtime which objects are alive, are
bookkeeping, not program memory, and are accepted as scalar stores and loads.

Slot names identify storage, `%N` values hold scalar values or address provenance, and
`$"x"` produces the address of local storage. The checker tracks provenance through pointer
stores, loads, and pointer casts. It does not infer reference exclusivity from `ref`.

A CFG builder handles structured blocks, if/else, loops with steps, break/continue, labels,
goto, return, and unreachable. A forward worklist computes possible initialization and lifetime
states at each reachable node, joining all incoming paths. Diagnostics are emitted after convergence.
Pointer origins are unioned at joins. Scope end invalidates existing pointer origins, including
register copies, so redeclaring a slot cannot revive a pointer to its previous lifetime.

Implemented checks:

- Reading a local that may be uninitialized.
- Reading or writing storage after its scope ends, including indirect accesses.
- Returning an address derived from local storage, including mixed local/parameter paths.
- Initialization through a pointer with one known local destination.

Scalar parameters start initialized at entry; their local slots become initialized through the
frontend's parameter stores. Pointer parameters refer to external storage under caller obligations.
The checker does not validate those obligations across calls yet. It assumes well-typed Path B IR
from the frontend; it is not an independent IR type verifier.

## Explicit shared and exclusive loans

The follow-up loan layer introduces two forms:

```text
(let %0 (ptr int) (borrow (ptr int) "L" shared $"x"))
(loan-end "L")
```

`exclusive` is the other borrow kind. Borrowing requires an initialized, live direct local
place or constant-offset field range and creates a loan whose ID is unique within the function.
Pointer copies, stores, loads,
and pointer casts preserve that identity. The QBE emitter evaluates `borrow` as its address
operand and emits no code for `loan-end`; both the emitter and its oracle validate their shape.

A shared loan permits reads and prevents writes to overlapping storage. An exclusive loan prevents
other accesses, while reads and writes through its own pointer remain permitted. Creating a
conflicting loan, writing through a shared loan, or ending storage with an active loan is an
error. Access through an ended loan is an error even through an older pointer copy. Possible
active loans are unioned at CFG joins, so a loan ended on only one incoming path still constrains
accesses at the join. A pointer carries a loan only on paths where that loan is active, because ending a
loan, its inferred expiry, and the end of its storage all rewrite every pointer that carries it. So an
access through a pointer needs its loans possibly active, not active on every path. After
`p = c ? &a : &b`, each loan is active only on its own branch, and `*p` is still allowed. A pointer
copy kept from an ended loan reads as ended and is an error. Local names and internal provenance tokens
occupy distinct namespaces.

By default, loan ends are **explicit**. The opt-in inference mode below can shorten them.
IDs may execute repeatedly in a loop
if each iteration ends the loan before the next creation; old pointer copies remain expired.
Field-sensitive overlap and loans on external storage are still refused. Ordinary C++ references
do not automatically acquire shared or exclusive loan semantics. Neither frontend emits these
new forms yet.

## Parent/child reborrows

A reborrow names both its own loan and the parent loan whose pointer it uses:

```text
(let %0 (ptr int) (borrow (ptr int) "parent" exclusive $"x"))
(let %1 (ptr int) (reborrow (ptr int) "child" shared "parent" %0))
(let %2 int (load int %1))
(loan-end "child")
(store int %0 (const int 7))
(loan-end "parent")
```

The child inherits its parent's local referent. The source pointer must preserve exactly the
declared parent identity, including through copies and pointer slots; a raw address cannot forge
that relationship. Unknown parents, cycles, and duplicate IDs are malformed IR. Ambiguous or
mismatched source provenance is refused.

An exclusive parent permits shared or exclusive children; a shared parent permits only shared
children. Access through a child requires its entire ancestor chain to be active. Ancestor loans
authorize child access instead of conflicting with it; siblings still undergo ordinary conflict
checks. An exclusive child blocks parent reads and writes. Shared children permit parent reads
but prevent parent writes. Ending a child restores access through the parent, subject to any other
active children.

Ending a parent with a possibly active descendant is an error. It also expires descendant pointer
copies so neither reactivating the parent nor reusing a static loan ID in a loop revives them.
The default mode requires explicit loan ends. The QBE emitter and its oracle erase `reborrow`
to the source pointer, preserving runtime code generation.

## Two-phase loans

`two-phase` is a third borrow kind, Rust's two-phase borrow of an autoref'd method receiver
(`c.set(c.get() + 1)`):

```text
(let %0 (ptr int) (borrow (ptr int) "a" two-phase $"x"))
(let %1 (ptr int) (borrow (ptr int) "b" shared $"x"))
(let %2 int (load int %1))
(loan-end "b")
(store int %0 %2)
(loan-end "a")
```

The loan is created *reserved*, and while reserved it is a shared loan: reads of the place and shared
loans of it are allowed, writes and exclusive loans conflict. Its first use *activates* it: an access
through its pointer or a child's, or a call argument that is the pointer or memory holding it. Copying,
storing and loading the pointer do not. At activation every other active loan overlapping its range is
a `loan-conflict`, as for an exclusive loan created there, and from then on it is exclusive. The phase
is a per-path state: after a join where only one side activated the loan it counts as exclusive, and a
later use re-checks activation. Each creation reserves it again. With `--infer-loan-ends`, a shared
loan whose last use comes before the activation has expired by then, which is the Rust case. The QBE
emitter erases it like the other kinds.

## Inferred loan ends (opt-in)

```sh
scripts/mrb scripts/pathb-borrowck.rb --infer-loan-ends example.ir
```

This mode shortens local loan lifetimes to their last possible use, without changing the input IR
or generated code. For example, this is accepted with inference and rejected in explicit mode:

```text
(let %0 (ptr int) (borrow (ptr int) "L" exclusive $"x"))
(let %1 int (load int %0))
(store int $"x" (const int 2))
```

If a later statement uses `%0`, the direct store remains a conflict. Copies and pointer-slot
loads retain the original loan's demand. A live child keeps all its ancestors live, and finishing
a child can restore parent access while the parent is still needed later.

The checker first solves forward provenance without shortening loans. It then records loan uses
and definitions from those converged states and solves backward demand on the CFG. Loan creation
kills demand for the previous instance of its static ID; explicit ends and storage ends are also
boundaries. The final forward pass expires active loans separately on each edge where the successor
has no demand. Expiry invalidates pointer copies, preventing old loop-iteration pointers from being
revived by another creation of the same ID.

Branch successors can therefore release different loans, while joins and backedges preserve loans
that might still be used. The demand set includes reference copies, even when their destination is
unused. Joined provenance and the per-loan demand model are conservative: this is not path-sensitive
reference-carrier liveness, dead-code elimination, or a complete implementation of Rust NLL.

Explicit `loan-end` remains a hard boundary. An end after an inferred expiry is accepted, but an
explicit early end still invalidates later uses, and ending twice is still an error. Inference cannot
bypass uninitialized borrows, permission checks, local-address returns, or unsupported-operation
refusals. A dangling use can be diagnosed as an inactive loan after inferred expiry rather than as
use-after-scope. Language-level region contracts remain future work.

## Explicit value moves and copies

```text
(let %0 int (copy-value int $"x"))
(let %1 int (move-value int $"x"))
(store int $"x" (const int 3))
```

`copy-value` reads the value and preserves initialization. `move-value` reads the value and marks
its source as moved. Later reads, copies, borrows, or moves of that source are errors until a store
reinitializes it. A move conflicts with every overlapping live loan of the source, including shared loans.
Copying has normal read permissions. These rules apply in both loan modes; inferred expiry can
permit a move after the loan's last use.

Initialization states join across all CFG paths, including backedges: a move on one path prevents
an unconditional later read. Reinitializing on every incoming path restores reads. A store through
a known single-local alias can also reinitialize storage, and moving a value back into its own
source is modeled in evaluation order. Scope end remains separate from move state.

For pointer values, transfers preserve referent and loan provenance. Moving a pointer slot makes
that slot unreadable but leaves the transferred pointer usable under the original loan's
permissions and ancestor lifetimes. Physical bytes are not cleared. Both value-transfer forms
lower to ordinary typed loads, with initialization policy enforced by the separate checker.

This is an **explicit IR ownership contract**, not trait inference. The frontend must select copy
versus move from the source language's rules, including Rust's `Copy` trait; the checker does not
prove that a type is copyable. Scalar representations in tests can model consuming handles and
are not claims that moving a Rust integer makes it unusable. Transfers currently require
scalar/pointer values in direct locals or constant-offset fields.
Whole-aggregate value transfers, moves through arbitrary aliases, drops, and ownership effects
of calls remain unsupported. The mrustc route emits `move-value` for Rust moves, one per scalar of the
moved place ([mrustc-borrowck.md](mrustc-borrowck.md)); the C++ frontend emits neither form.

C++ `rref-arg` is still refused: an rvalue-reference argument alone does not authorize treating the
source as dead. Ordinary C++ moved-from objects can remain usable; their contracts need separate
modeling before a frontend can emit a consuming transfer.

## Field ranges and partial moves

The checker now accepts bounded aggregate slots and the IR's existing constant byte offsets:

```text
(slot "s" (struct "Pair") 8 4)
(decl $"s" val)
(store int (offset $"s" 0) (const int 1))
(store int (offset $"s" 4) (const int 2))
(let %0 int (move-value int (offset $"s" 0)))
(let %1 int (load int (offset $"s" 4)))
```

Moving the first four bytes leaves the second field usable. Reading the moved field fails until
all its bytes are reinitialized. Partial writes restore only the bytes they cover; repairing half
an integer does not restore that integer. Per-byte state joins preserve these distinctions across
branches and loops. Diagnostics show half-open byte ranges, for example `s[4..8]`.

Typed loads, stores, and value transfers determine access widths. Slot size and constant offsets
bound every access. Disjoint field loans can coexist, while overlapping ranges conflict, including
cross-width accesses and overlapping union storage. This does not check union active-member rules,
type punning legality, or source-language rules prohibiting partial moves from destructor types.

A reborrow may narrow its parent's range:

```text
(let %0 (ptr (struct "Pair")) (borrow (ptr (struct "Pair")) "parent" exclusive $"s"))
(let %1 (ptr int) (reborrow (ptr int) "child" exclusive "parent" (offset %0 4)))
```

The child must fit entirely inside its parent. Its explicit source offset must match the actual
pointer provenance. Offsets hidden in earlier register assignments are refused if they cannot be
matched to the declared range. Ancestor authorization and sibling conflicts apply only where ranges
overlap; using a parent on a disjoint field can remain valid while another child is live.

Projected pointers preserve their original loan identity for last-use inference, and expire with
their enclosing storage or loan. Redeclaring a slot cannot revive an old projected pointer. Pointer
fields retain provenance for an exact byte range; a write overlapping that range makes the pointer
value unknown. Writes to disjoint fields preserve it. `zero-fill` initializes the specified bytes,
but does not establish usable pointer provenance.

This initial model supports LP64 widths and slots of 1–4096 bytes. It refuses other supplied data
layouts, dynamic offsets outside local arrays (see [Array indexing](#array-indexing)), out-of-bounds
constant accesses, projections of pointers of unknown provenance, and accesses outside a loan's range. A constant
offset or a dynamic index from an external pointer is external memory: C++ pointer arithmetic stays inside the
object it started in, which is not this frame's (no local address is ever stored into external memory), and
accesses to external memory are not tracked (`index/external_*.ir`). Aggregate value loads and moves remain refused; aggregate copies are described below. Without semantic metadata,
whole-object loan widths come from the matching root slot. With the metadata below, nested aggregate
widths come from validated descriptors. Unknown nested widths are refused. Constant offset forms are accepted as address operands by both QBE emitters as well as in ordinary
three-address IR, and explicit projected moves/copies lower to the same typed loads.

## Aggregate copies

`(copy N DST SRC)` copies byte states. Each destination byte takes the state of its source
byte, so copying a struct with uninitialized padding or fields is not an error. A later read of
the uninitialized part still is. Pointer values that lie wholly inside the copied range keep their
provenance at the new offset; other pointer values in the destination range become unknown.

- The source must be alive and unmoved, and an exclusive loan over it conflicts.
- The destination is checked as a write: alive, and no live loan overlaps it.
- External memory reads as initialized bytes holding no known pointers. Copying a local address
  into external memory is refused. Copying one into argument memory under a verified summary is
  `contract-escape`.
- Unknown or aliased places, dynamic indices, and drop-obligated storage are refused.

A `byval` parameter's register is the address of the callee's own copy of the argument. The
checker models that copy as a synthetic local slot `*%N`: initialized, alive until
`(scope-end %N)`, and holding pointers of unknown provenance. Returning its address is
`return-local-address`. Its size comes from the slot's semantic layout or from the module's
`(abi-type "N" SIZE ...)` record.

The argument effect `(byval T)` describes such a parameter in a call summary, and the call passes
`(byval T PLACE)`. The caller's object is read: its fields must be initialized (padding is exempt
when `T` has a layout), and nothing is retained. Verifying the callee checks its own copy, the
synthetic slot. Summary inference gives a `byval` parameter `(byval T)` when `T` has a semantic
layout, so `long double` and `__int128` by-value parameters, which have none, get no summary yet.
All three validators accept the effect.

`(byval-deep T)` is `byval` for a callee that also reads what the value's pointers reach, as Rust's
`std::io::_print` reads the values a `fmt::Arguments` refers to. At the call, each pointer stored in
the argument is followed, transitively: its referent (the range of its loan, or the rest of its slot)
is read as a copy reads, carrying byte states, and its loans count as used there. A pointer to ended
storage or through an ended loan is an error, and one of unknown provenance is refused. The callee
still writes nothing and keeps nothing. Summary inference never chooses it; the mrustc translator
emits it ([mrustc-borrowck.md](mrustc-borrowck.md)).

## Source locations

With `NFCXX_IR_LOC=1` the frontend prints `(loc "FILE" LINE)` statements, and each diagnostic names the
location of the statement it concerns: `main: uninitialized: x at FILE:6`. A statement takes the most
recent `loc` above it in the text. Without `loc` statements the messages are unchanged.

## Array indexing

`(index P I SIZE)` with a constant `I` is the constant offset `I * SIZE`. With a dynamic `I`, the
result is a *ranged* pointer: it points somewhere inside the array that `P` names. That is the
whole slot when `P` is derived from a local slot of `(array N T)` type, or the loan's range when `P`
is derived from a loan of such a slot. Ranged pointers have these rules:

- A read through one requires every byte of that range to be initialized, unmoved, and alive.
- A write is a *weak update*. It must be allowed on every byte, and live loans over any part of the
  range conflict with it, but it initializes nothing. So `for (int &x : a) x = 0;` does not make
  `a` initialized. Initializing an array element by element needs constant indices.
- A pointer store through one, a borrow or reborrow from one, and a store into drop-obligated
  storage are refused. A non-pointer store through one makes pointer values held in the range unknown.
- At a CFG join, different offsets from one array base widen to that base's ranged pointer. A
  pointer advanced in a loop, such as the iterators of a range-based `for`, therefore converges.

Comparing pointers (`eq`, `ne`, `lt.u`, `le.u`, `gt.u`, `ge.u`) is allowed and yields no provenance.
`(bounds IDX N)` evaluates its operands. The checker assumes a dynamic index stays inside its
array: it proves temporal safety, not bounds. Path B's runtime `bounds` checks cover subscripts of
arrays of known length, but not pointers advanced by other arithmetic. Pointer arithmetic on
anything other than a local array or external memory is refused. That includes argument regions, so a callee
that indexes its pointer argument gets no inferred summary.

The underlying model tracks **physical byte initialization**. Without semantic metadata,
whole-object loans conservatively require all bytes initialized, including padding. Ordinary field
accesses do not require padding initialization. The C++ integration tests cover field initialization,
references to padded structs, uninitialized fields, and dangling field pointers.

## Semantic struct layouts

Optional module-level metadata separates value fields from physical padding:

```text
(borrow-layout (struct "Pad") 8 4
  (field "a" 0 char)
  (field "b" 4 int))
```

The size and alignment are 8 and 4 bytes. Field names are unique, offsets are absolute within the
struct, and field types determine widths and alignment. Scalars, pointers, other declared struct
layouts, and arrays `(array N T)` of these (1 to 4096 bytes, aligned like `T`) are supported, including
as struct fields. The
same types describe call-effect arguments, such as `(read (array 16 unsigned_char))`. Pointers do not recursively embed their pointee, so self-referential pointer
types are valid. By-value cycles, missing nested layouts, duplicate fields/layouts, and out-of-bounds
fields are errors. Overlapping or unaligned fields, empty arrays, and union descriptors are refused.
This excludes packed layouts and overlapping empty subobjects for now.

A slot using a known layout must match its size and provide sufficient alignment. Known aggregate
borrows must identify the root object or a declared nested subobject of the requested type at the
correct offset. An arbitrary same-size byte range cannot claim a different struct's initialization
mask. Layout validation runs before analysis and before code-generation pruning, including for
unused descriptors.

Whole-aggregate borrow and reborrow creation checks only declared field bytes, recursively ignoring
padding. Every field must still be initialized and unmoved. Empty structs with positive physical
size have no field initialization requirements, but their storage must still be alive. Slot storage
size zero remains unsupported. Loan conflicts and bounds continue to cover physical ranges;
semantic padding does not authorize an overlapping write through a live loan.

These facts **do not initialize padding**. Ordinary typed loads, copies, moves, and zero-fill retain
physical-byte behavior. A raw integer read spanning uninitialized padding still fails after a valid
semantic aggregate borrow. Missing metadata retains the conservative physical-byte fallback.

Both QBE emitters validate the descriptor graph and emit no code for it. Removing metadata produces
identical QBE and native behavior. Layout records are trusted frontend contracts: validation checks
internal consistency, not correspondence with Rust or C++ source or completeness against a source
type. Source-language drop, active-member, and trait rules remain separate work.

With `NFCXX_PATHB_BORROW=1` the C++ frontend prints a record, once per module, for each struct
that a slot holds or points to, and for the structs nested in those. The records go after the
module header. A struct gets a record only if every non-static data member is a named scalar
(`bool`, the `char` and integer types, `float` or `double`; an enum prints as its underlying
type), a pointer, an array of these, or a struct that itself gets a record, and is naturally aligned
within its object. A struct with a base class, a bit-field, a union, a `long double` member, a
`[[no_unique_address]]` member, an anonymous member, or two members of one name (a lambda's
captured pack) gets none, and the checker keeps requiring all of its bytes. Distinct types that
print under one name, such as a local struct in each instance of a function template, share a
record when their records agree. Otherwise neither gets one, and neither does any struct that
holds one. A record the frontend prints therefore never makes the checker refuse. On the 93
corpus programs that get records, checker results are the same with the records removed.
The frontend also records the three by-value pseudo-structs of its floating and wide integer types,
which are passed as `(byval (struct "__nfcxx_ld"))` and its siblings: a `long double` has 10
significant bytes, and `_Float128` and `__int128` have 16. Records are not printed for them without
the flag, and `(abi-type ...)` is unchanged. A value of such a type is a byte array in the IR
(`(array 16 unsigned_char)`), so a byte array of the struct's exact size at offset 0 is accepted as
holding that struct, with the struct's significant bytes required.
Neither frontend emits ownership loan/transfer forms yet.

### Throwing calls

A callee's summary may say `(may-throw)` instead of `(nothrow)`. Such a call can leave the function by
an exception, so the checker handles it like this:

- The normal return is checked as for any call.
- The exceptional edge is not followed. The runtime unwinds: it runs the destructors that the frames
  pushed by this function, and by its callers, register, and it leaves every frame of this function
  popped. Every local of this function then dies, and the checker's exit contracts apply only to
  normal returns, since a caller never sees the outputs of a call that threw.
- A destructor run by the unwind is the one the normal path checks at the object's scope end, on an
  object that is initialized, since the runtime registers an object only after its construction. Its
  summary is closed, so it writes only that object. The unwind therefore needs no state of its own. This
  is the one assumption the model rests on, and the summaries it relies on are the trusted ones.
- A call is refused while a drop obligation is `live`, because the unwind would have to discharge it,
  and no frame does so for an explicit obligation.
- Summary inference verifies each candidate as `may-throw`, so a throwing body is not a contract
  violation, and then writes `(nothrow)` for a body that calls no throwing callee. Self-recursion does
  not make a function throw. A function that calls a `may-throw` callee is inferred `may-throw`.

The `throws` fixtures and `contracts/throws.cpp` cover the normal-path rules above.

### try and catch

EDG lowers a try block to a frame of kind 5 and `if (_setjmp(frame.buffer) == 0) BODY else HANDLER`
(`docs/notes/pathb-stage3.md`, "C++ exceptions"). The checker recognizes that `if`: its condition is
`(eq R 0)` with `R` the result of `_setjmp` on a pointer into a local slot, the frame. `_setjmp` returns 0
first, so the handler has no edge from the `if`. It is entered by exceptional edges from the throw points
of the body: calls of `__throw`, `__rethrow`, or a `may-throw` callee.

- A throw point reaches the handler of every enclosing try block of the function, because the
  exception's type is not known statically, except that a handler that catches everything ends the
  search. A handler catches everything when it has no dispatch on `__catch_clause_number` (a lone
  `catch (...)`), or when its dispatch chain ends in a final `else` (a last `catch (...)`). A typed chain
  has no such `else`: the runtime longjmps only into a try whose catch table matches. For the same reason,
  the "no clause matched" fall-through of a typed chain is not a path. EDG's lowering leaves dead code
  there, such as `main`'s implicit `return 0` without its frame pop.
- A throw inside a handler goes to the enclosing try blocks, not to the handler's own.
- The state at the handler's entry joins the states before and after the throwing call, since the callee
  may have applied any part of its effects. Every slot declared inside the try body is ended, because
  unwinding destroyed it (with the destructors the normal path checks), and pointers to it dangle. The
  exception-stack top is the try's frame, as the runtime's longjmp leaves it.
- `__throw` and `__rethrow` do not return.

The exception object is the runtime's storage, with provenance `eh`. `__throw_setup` and its variants
return it (their arguments may not hold a local address), and a load of `@"__caught_object_address"`
yields it. Reads and writes through it are not tracked and are not `contract-not-closed`, since it is not
the caller's memory. A local address stored into it is refused, because the exception may outlive the frame. That refusal is
conservative: `int v; try { throw &v; } catch (int *p) { ... }` is valid C++ when the same function
catches it, but the exception object's contents are not tracked, so the checker cannot tell.
A call may take it as an argument, such as the exception's constructor, and the call's effects on it are
not tracked. `__destroy_exception_object` ends it: a pointer to the caught object used after its handler
is `use-after-scope: exception object`. Returning its address is refused. `@"__catch_clause_number"` is
scalar bookkeeping, and `__exception_caught` is a no-op.

Summary inference does not use catch clauses to prove a function `nothrow`: a function with a throw
point is `may-throw` even when its own handler catches the exception. `contracts/try_catch.cpp` checks
a typed clause with a `catch (...)` after it and a rethrow, and runs natively.
`contracts/try_catch_errors.cpp` has one function per handler-path rule: an initialization after the
throwing call, a pointer to a body local, the caught object after its handler, an outer handler reached
directly past a typed inner one, and the two correct counterparts (initialization before the try, and an
outer handler reached only through the rethrow of an inner `catch (...)`).

## Explicit drop-state contracts

Drop-state forms describe an ownership protocol for declared local values. They are **checking
facts**, not destructor instructions: the producer must supply any real cleanup and runtime guard
code separately. Neither frontend emits these facts yet. The bounded call contracts below can
connect actual calls to checking effects; they do not prove general destructor, deallocation, or
unwind behavior.

```text
(drop-obligation "x" int $"x")
(decl $"x" val)
(store int $"x" (const int 7))
(drop-live "x")
(drop-state "x")
(scope-end $"x")
```

`drop-obligation` is function-level metadata with a unique nonempty ID, value type, and direct
local or constant-offset field place. Scalar/pointer values and aggregates with known semantic
layouts are supported. Obligations cannot overlap; nested destructor/field cleanup requires a
future hierarchical contract. These annotations assert a non-bitwise-copyable owner policy;
integer examples model consuming handles rather than Rust integer types implementing `Drop`.

The protocol tracks five states:

| State | Meaning |
| --- | --- |
| dead | Target storage has not started or has ended. |
| vacant | Live storage has no registered value, including after a move. |
| building | Writes started constructing/reconstructing a value, but it has not been registered. |
| live | Construction completed and cleanup is owed. |
| dropped | The registered value was consumed by a cleanup fact. |

Writes to vacant or dropped storage mark construction in progress. `drop-live` registers completed
construction and requires every semantic field byte initialized; padding is excluded. Empty structs
can be registered without field writes, while still requiring live storage. Repeatedly registering
a live value is an error. Reinitialization after a move or cleanup requires a new registration.

A whole-value overwrite of a live owner is an error until its prior value is consumed. Field
mutation preserves the enclosing live obligation. Exact typed moves clear the source obligation;
partial or reinterpreted moves of that owner are refused. Explicit bitwise copies of a live owner
require a copy contract and are refused. A non-owning aggregate can instead declare separate,
disjoint field obligations, allowing one field to move while siblings still require cleanup.
Tracking the destination or result of a move is the producer's responsibility; this is not a proof
of leak freedom or a replacement for source-language move/copy policy.

`drop-state` requires the value live on every incoming path. `drop-state-if-live` consumes only live
paths and skips vacant or already-dropped paths, allowing cleanup after conditional construction or
moves. Construction-in-progress is never silently skipped: missing registration remains an error
after guarded cleanup. Guarded facts still require live storage; they cannot extend declaration
lifetimes. Flags preserve the correlation between a live value and its initialized field bytes.
Loan conflicts remain conservative at joins rather than using full relational path reasoning.

Both forms check overlapping live loans as a consuming access. Last-use inference can release a
loan before cleanup. Known pointer-field loan identities are conservatively kept needed through
consumption; no pointee access or free is proved. Cleanup marks bytes logically dropped without
clearing physical memory. Later reads, borrows, and moves fail until reinitialization. A second
unconditional consumption is an error; repeated guarded cleanup can legitimately do nothing.

Normal returns, fallthrough, storage end, and redeclaration reject live obligations or unfinished
construction. Explicit `unreachable`/abort paths do not require cleanup; exception cleanup edges
remain unsupported. The marker asserts that the matching real cleanup or runtime guard exists;
the checker does not generate or verify that code. The QBE emitter and oracle accept these facts
as validated no-ops, and a native integer test verifies marker erasure preserves generated code.

## Closed call-effect contracts

Actual direct calls can now use an explicitly trusted module-level summary:

```text
(call-effects "finish" (returns void)
  (nothrow) (noescape) (closed)
  (args (consume int)))
```

The argument list is complete and ordered. Every call must match its contract's arity and return
type. Known scalar argument ABI classes must match; memory arguments must use pointer-width
representations with known local provenance. This is not full C/C++ prototype verification.
Contracts are validated before pruning, including unused declarations.

| Argument effect | Required behavior and analysis |
| --- | --- |
| `value TYPE` | A nonpointer scalar value; carries no tracked address provenance. |
| `read TYPE` | Reads an initialized value through the argument without changing it. |
| `write TYPE` | Reads/mutates an existing initialized value, preserving its ownership identity. |
| `init TYPE` | Definitely initializes the value's required bytes without reading the old value. |
| `consume TYPE` | Consumes a matching live drop obligation on normal return. |

`nothrow` excludes exceptional continuations. `may-throw` is the same contract with an exceptional
continuation, which the checker handles as described under "Throwing calls". `noescape` promises that argument addresses are not
retained beyond the call, except for an explicitly declared returned alias. `closed` promises no access to globals, hidden pointees, or other externally
visible memory outside the declared argument regions; private callee-local storage is permitted.
These are trusted imports at call sites, not facts inferred from names. For an external callee the
producer must ensure the real implementation satisfies the summary. A function defined in the same
module is checked against its own summary (see below).

Read effects may have several possible known local targets, all of which are checked. So may mutation,
as a weak update of each (see "Refusals and limits"). Initialization and consumption require one known
place. An argument that points only into external memory (a global, or a pointer parameter of a function
checked without a summary) is accepted for `read`, `write` and `init`, as a load or store through it would be:
that memory is not tracked and is not the caller's storage, so it overlaps no local argument, and `noescape`
keeps argument pointers out of it. A returned alias into it is external memory. Under a verified summary it is
`contract-not-closed`. `consume` and an argument that may be external or local are still refused
(`calls/external_*.ir`). Read/read aliases are allowed; arguments
whose ranges overlap and include mutation are refused before applying postconditions. Summaries do
not prescribe ordering inside a callee, so an initializer cannot silently make a same-call reader
safe. More permissive alias/ordering contracts remain future work.

Effects respect loan permissions and ranges. Shared loans cannot authorize mutation or
initialization. Stored pointer identities are counted as possible uses when a call reads them,
so last-use inference cannot end those loans before the call. Mutation and initialization forget
resulting pointer provenance. Unknown returned/outgoing pointer relationships are never guessed.

Typed aggregate initialization establishes only declared field bytes. Mutation preserves existing
field initialization. Both forget padding initialization, even if the caller previously zeroed the
object: the summary does not promise defined padding on return. Read effects do not erase padding.
`init` starts construction for intersecting drop obligations; a following `drop-live` registers the
completed owner. Reinitializing an already-live owner without consuming it remains an error.

A consuming call must target an unborrowed owned place with an exact matching obligation and live
flag. Its normal-return postcondition performs the same logical consumption as `drop-state`, so a
separate marker is unnecessary. Unlike a marker, the **call itself remains executable code**. A
consume call does not implicitly drop a possibly absent value; guard correlation and unwind cleanup
remain unsupported. Passing an exclusive loan alone does not establish ownership for consumption.

This stage supports direct symbols, void/scalar results or the returned aliases below, and bounded local argument effects.
Indirect/variadic calls, uncontracted pointer/reference or aggregate returns, unknown external targets, retained
borrows, heap/deallocation effects, hidden globals/pointees, and potentially throwing calls remain
refused. A native test links small C helpers and observes actual initialization/read/mutation/
consumption results. It demonstrates call execution and state propagation, not general destructor
or resource-release verification. Removing the summaries leaves identical QBE while the checker
correctly returns to refusing those calls.


### Runtime helper summaries (`--effects`)

`--effects FILE` loads trusted `call-effects` forms for functions the module does not describe.
The option can be repeated. Lines starting with `;` are comments, and any other form is
malformed. A summary in the module itself takes precedence over a file's summary of the same
name.

`scripts/pathb-libc.effects` describes the few C library functions whose effects a closed summary can
state exactly: scalar arguments and results, no memory access, no throw (`sched_yield`, `getpid`, `abs`,
`labs`, `llabs`, `fabs`, `floor`, `ceil`, `trunc`) and glibc's pure floating predicates
(`__issignalingf`, `__issignaling`, `__issignalingl`, `__iscanonicalf`, `__iscanonical`, `__iscanonicall`). The C23
quiet comparisons `__iseqsig*` raise FE_INVALID on NaN, a global status the model does not track, so they have no
summary.

A summary in an `--effects` file that the module cannot state, such as one over a `long double` in a module that
never uses that type, is dropped. A call the module makes to such a function is refused at the call, as it would be
with no file; a malformed file is still an error. A function that takes a pointer of unknown size (`memcpy`,
`strlen`), is variadic (`printf`), or keeps a pointer (`pthread_create`) has no such summary. Neither does
one that returns storage of unknown provenance (`malloc`, `__errno_location`), since the checker cannot
name what it returns. `sqrt` and the conversions are left out because they set `errno`, which is global.

Scalar floating operations (`fadd` and its siblings, the comparisons `lt.f` and so on) and the conversions
`cf2i`, `i2f`, `u2f` and `fconv` are value operations on scalars, and they are checked like the integer ones.
A checked conversion traps on NaN or an out-of-range value, which is not a memory access, so the checker
does not model the trap.

`scripts/pathb-runtime.effects` describes the Path B runtime helpers of `be/nfcxx_ldrt.c` that
implement `long double`, `__int128`, and `_Float128` operations, 106 in all. Each value is a
16-byte object. A helper writes all 16 bytes of its first pointer argument (`init`), reads its
`const` pointer arguments (`read`), and touches no other memory. Helpers for bit-fields, `va_list`,
and the UBSan report are not described. Like every summary, these are trusted, not verified. The
file is generated from the helper signatures, and each writer was checked to store all 16 bytes.

## Returned alias loans

A trusted summary may return a pointer into one argument's declared memory region:

```text
(call-effects "identity"
  (returns (ptr int) (from-arg 0 0 shared))
  (nothrow) (noescape) (closed) (args (read int)))
(let %r (ptr int)
  (call-borrow (ptr int) "R" root &"identity" $"x"))
```

`from-arg` takes a zero-based argument index, a nonnegative byte offset, and `shared` or
`exclusive`. The returned pointee must fit wholly inside that argument's region. Shared results
require a `read` or `write` source; exclusive results require `write`. `value`, `init`, and `consume`
sources are refused. A result pointer to `const`, such as `(ptr (const int))`, grants no writes,
so its alias must be `shared`. Its width comes from the unqualified pointee. The checker, the
QBE emitter, and the emitter oracle validate this identically. An ordinary `call` cannot discard
the required returned-loan identity.

`root` requires a direct local place or constant offset. For a result derived from an existing
loan, use `(parent "P")` instead; the actual source must preserve that parent's identity and
constant offset. The result cannot upgrade shared permission, outlive the parent or referent,
or escape the checked function as a local address. Existing `loan-end` and opt-in last-use inference
apply to the returned loan and its ancestors. Field-range results protect only their returned range
after the call, while call preconditions still cover the complete argument effect region.

These contracts remain trusted: the checker does not inspect the callee to prove where its pointer
actually points. Heap-owned returns, retained borrows, generic lifetime signatures, and Rust
frontend emission remain unsupported. The emitter erases `call-borrow` to an ordinary call. A native C identity helper verifies the actual pointer return,
write through the result, byte-identical metadata erasure, and emitter/oracle agreement.

### Several sources

A result that may point into any of several argument ranges lists one `from-arg` per range:

```text
(call-effects "pick"
  (returns (ptr int) (from-arg 0 0 shared) (from-arg 1 0 shared))
  (nothrow) (noescape) (closed) (args (read int) (read int) (value int)))
(call-effects "get"
  (returns (ptr int) (from-arg 0 0 exclusive) (from-arg 0 4 exclusive))
  (nothrow) (noescape) (closed) (args (write (struct "Pair")) (value int)))
```

These are `fn pick<'a>(a: &'a i32, b: &'a i32, c: bool) -> &'a i32` and NLL's "problem case 3", a
`&mut` result that borrows one of two fields. Each source is validated as above. Two sources in one
argument must not overlap, since a call takes a loan of each, and two exclusive loans of one byte
would conflict with each other. At a call, the result's provenance is the union over the sources:

- A source whose argument is a pointer value contributes that pointer moved by the source's offset,
  with its loans.
- A source whose argument is a local place gets an implicit loan, as below. With several sources,
  these loans are named `&CALLEE#N.K`, for the K-th source of the N-th call site.

The result therefore keeps every source borrowed while it is live. A write to any source then
conflicts, and the end of any source's storage leaves the result dangling. A read through the result
reads every possible place. A write through it is a weak update of each (see "Refusals and limits").
`call-borrow` names a single loan, so it is refused for a summary with several sources.

## Verified callee summaries

When a module defines a function and also declares `call-effects` for its name, the checker
checks the body against the summary while analyzing that function. Callers keep using the summary
as before, so a module whose definitions all verify no longer depends on trusting them.

The signature must agree: the return type is the summary's result, the parameter count is the
argument count, `value` parameters are nonpointer scalars of the same ABI class, and memory effects
take pointer parameters. Disagreement is malformed IR.

Each memory argument `%N` points to a synthetic region named `*%N`, sized by the effect type.

| Effect | Region at entry | Access inside the body | Required on every normal return |
| --- | --- | --- | --- |
| `read` | declared fields initialized | through a shared loan `*%N` | nothing |
| `write` | declared fields initialized | through an exclusive loan `*%N` | declared fields initialized |
| `init` | uninitialized | through an exclusive loan `*%N` | declared fields initialized |
| `consume` | live drop obligation `*%N` | owned place | obligation consumed or moved |

The argument loans last for the whole call. They cannot be ended with `loan-end`, and last-use
inference never expires them. The body can reborrow them (`(reborrow ... "c" shared "*%0" %0)`) or
use them as a `call-borrow` parent. A consumed argument is released by `(drop-state "*%N")` or by
passing it to another consuming call. Padding never counts as initialized at entry. A `write`
argument does not track the drop obligations of its caller.

The other promises are checked as follows:

- `closed`: any load or store through external storage, such as a global, is `contract-not-closed`.
  Pointer values loaded from argument memory have unknown provenance and are refused when used.
- `noescape`: storing a local, argument, or loan-derived pointer into argument memory is
  `contract-escape`. Storing a pointer of unknown provenance there is refused. Returning an
  argument pointer is allowed only through the declared returned alias.
- Returned alias: every returned pointer must lie in a declared source's argument region at that
  source's offset. An `exclusive` source also needs an all-exclusive loan chain. A returned
  pointer that matches no source is `contract-return-mismatch`, naming the region of a source in
  the same argument, or else the first source's region.
- `nothrow`: every call in the body already needs a contract, and no contract the body calls is `may-throw`.
  A body that calls a `may-throw` callee, other than itself, is `contract-may-throw` under a `nothrow` summary.

A verified function needs no local declaration facts beyond `(decl %N param)`. Region names
cannot collide with local slots, symbols, or loan IDs. A body that calls an uncontracted function
is still refused. Recursive and mutually recursive definitions are checked against the same
summaries they use, so the summaries work as an inductive hypothesis. That is sound only for
partial correctness: a non-terminating call satisfies any summary. External definitions,
summaries that this module does not define, and C/C++ prototype correspondence remain trusted.

The fixtures are in `tests/pathb-borrow/verify`. The runner also lowers
`tests/pathb-borrow/contracts/callees.cpp` through the real frontend, prepends correct and incorrect
summaries, and checks both results. `tests/mruby/pathb-edge/verified_callee_facts.ir` links verified
callees with their caller and runs natively.

## Inferred summaries (opt-in)

```sh
scripts/mrb scripts/pathb-borrowck.rb --infer-summaries example.ir
```

This mode gives each defined function other than `main` that has no `call-effects` form a summary
inferred from its body. Each inferred summary is printed as an `inferred: (call-effects ...)` line
before the result, in a form the checker and both emitters accept. Callers are then checked
against it, exactly as for a hand-written summary. Explicit summaries are never replaced; they are
verified as before. The option combines with `--infer-loan-ends`, which applies both to the search
and to the final check.

The search is a verification loop, not a separate analysis:

1. Functions are visited callees first. A self-recursive call uses the candidate under test.
2. Scalar parameters become `value`. Each pointer parameter starts at `read` and moves to `init`,
   then `write`, only when a diagnostic names its region `*%N`. A diagnostic that names no argument
   region, or a refusal, ends the search with no summary. A parameter with a `(readonly %N)` fact
   (a Rust `&T`, from the monomir translator) is only ever `read`, and as a result's source only
   `read`/`shared`.
3. A pointer result tries each argument region and each aligned offset in turn. Its source
   argument tries `write`/`exclusive` first, because a pointer to non-`const` lets the caller
   write through it. It then tries `read`/`shared`, then `write`/`shared`.
4. The first candidate whose body has no diagnostics is kept.
5. If no single source verifies, the result tries the set of argument ranges that the candidates'
   bodies returned (on any path), once it has at least two. Each source argument's modes advance as
   in step 3. A candidate that returns a range outside the set adds it, and the larger set is tried,
   at most once per range. `pick` above returns `*%0` on one path and `*%1` on the other, so no
   single source verifies, and the set of both does.

A function with no surviving candidate keeps the plain analysis, and calls to it are still refused.
So inference cannot accept anything the verifier would reject. It can only fail to find a
summary. Pointee types come from the parameter types with `const` removed; `void` pointees,
aggregates without semantic layouts, and by-value aggregates are not inferred. A `const` pointer
result tries only `read`/`shared`, then `write`/`shared`. `consume` is never inferred, because it would assert an ownership policy that the body
alone does not establish. Mutually recursive functions get no summary and need explicit ones.

The order chooses one summary when several verify. `read` is preferred, and `init` over `write`,
so a callee that only stores gets `init`. A returned alias is `exclusive` whenever the body
allows it, even if the body only reads, so callers can write through the result. One source is
preferred over several, since every source stays borrowed at a call. The C++ `std::max` and `std::min`
of libstdc++ get two-source summaries this way.

## Implicit returned loans

A returned alias normally needs `call-borrow` to name its loan. The C++ frontend emits a plain
`call` instead. When a plain `call` matches a returned-alias summary and its source argument is a
direct local place or constant offset, the checker creates a root loan for that call site. The
source can also be a register defined once by a pointer `bitcast` of such a place. That is the
qualification conversion C++ inserts when it passes `&s` to a pointer-to-`const` parameter. The
loan is named `&CALLEE#N` and has the summary's permission and range, so

```text
(let %0 (ptr int) (call (ptr int) &"pick" $"x"))
```

checks like `(call-borrow (ptr int) "&pick#1" root &"pick" $"x")`. A summary with several sources
gets one such loan per source whose argument is a place, `&pick#1.1`, `&pick#1.2`, and so on (see
"Several sources"). Lowered C++ has no `loan-end`
facts, so these loans require `--infer-loan-ends`; without it the function is refused.

A source whose provenance is only known by dataflow, such as a pointer loaded from a slot, gets no
loan of its own. Rust passes such pointers: the argument is a reference the caller already holds.
The result is the source pointer moved by the summary's offset, with the same provenance, as a copy
of the pointer would be. Its uses therefore need the source's loans and storage live, and
`--infer-loan-ends` keeps them live while the result is used. A `call-borrow` with a declared parent
still names a separate child loan.

Together with `--infer-summaries` and the temporary facts, a lowered C++ program can be checked
end to end with no annotations. `tests/pathb-borrow/contracts/aliases.cpp`
passes `bump(second(&s))` through an implicit exclusive loan. A variant that writes `s.b` while it
still holds the alias reports `loan-conflict`.

## Refusals and limits

Exit status is 0 for supported local checks passing, 1 for a detected lifetime/initialization
error, 2 for malformed IR, and 3 when analysis is unsupported. Diagnostics identify functions and
slots, and name the source line of the statement when the IR has `loc` statements.

With `--emitted-only` the checker analyzes only the functions the QBE emitter keeps (its `prune`): external
definitions, `(constructor)`/`(destructor)` functions and alias targets, and whatever they refer to by `&` or
`@`, transitively, including through global initializers. A `(weak)` (inline, template) or `(static)` definition
nothing reaches is not emitted, so the checked code is the emitted code: another translation unit that needs a
weak definition has its own copy, checked with that unit. The many unused library instantiations of a hosted
C++ unit then no longer refuse it (`tests/pathb-borrow/emitted`). It is opt-in because a source language may
require more: Rust rejects a borrow error in a function nothing calls, and the Rust translator marks every
function `(weak)`.

`scripts/pathb-borrowck-tally.sh` lowers a corpus (by default the C++ programs under `tests/`) and counts the
verdicts and first refusal messages in four modes: plain, with `--infer-loan-ends --infer-summaries`, with the
runtime and libc effects files too, and with `--emitted-only` on top. On 139 lowered programs, before and
after accepting external projections and external call arguments (and adding `--emitted-only`):

| mode | accepted | errors | refused |
| --- | --- | --- | --- |
| plain | 35 → 38 | 11 → 11 | 93 → 90 |
| inferred | 70 → 72 | 13 → 13 | 56 → 54 |
| inferred, effects files | 74 → 76 | 13 → 13 | 52 → 50 |
| inferred, effects files, `--emitted-only` | — → 78 | — → 13 | — → 48 |

Every error stayed the same error. Counted with each function checked on its own, refused functions in the
inferred mode fell from 8416 to 6152, and to 759 among emitted functions. The leading program refusal is still
a call without a contract: mostly a module function that gets no summary, because a parameter points to a
struct with no layout record (`std::string`, `void *`), it touches globals, or its body is refused.

`(set %N OPERAND)`, which lowers `?:`, `&&` and `||`, reassigns a register. A pointer register
assigned on each branch carries the union of their provenance. `(null PTR)` has no provenance, so
it adds nothing at a join, and a value that can only be null cannot be dereferenced.

A store through a pointer that may name several places writes one of them. It is a *weak update*:
every place must allow the write (live storage, no conflicting loan, no shared loan), and each place
may keep its old contents. Its bytes become initialized only where they already were. A stored pointer
joins the provenance it may replace, which is none if the bytes were never initialized, and a scalar
store makes a pointer held there unknown. A `write` call argument that may name several places is
handled the same way. A store into drop-obligated storage, a dynamic index among the places, and `init`
or `consume` arguments still need one place. `cases/weak_store_*.ir` cover an uninitialized place, an
initialized pair, and a stored pointer to a local whose scope ends. Functions
with an `(ellipsis)` parameter are refused. A `byval` parameter is the callee's own copy (see
"Aggregate copies").

An aggregate result is returned through a caller's buffer, `(sret %N TYPE)` in the callee and
`(sret TYPE PLACE)` as the first argument of the call. The callee's buffer is a pointer parameter whose
summary mode is `init`: the callee must initialize all of the result's declared bytes, and the caller's
buffer is initialized by the call. Summary inference gives it that one choice. The result is therefore
checked like any other output, so a callee that leaves a field unwritten has no summary, and a caller
that uses the buffer before the call reports `uninitialized`. `tests/pathb-borrow/contracts/sret.cpp`
and `int128_return.cpp` cover the cases, the second with `__int128` passed and returned by value over
the runtime helpers. The C++ cases `cpp/conditional_*.cpp` cover a
pointer `?:`, an uninitialized branch value, and a branch pointer to an ended scope.

Calls without a supported closed effect contract are refused. So are rvalue-reference arguments,
aggregate values, dynamic indices, general pointer arithmetic, unknown pointer provenance,
and external stores. Unknown instructions are
refused. Escapes never establish initialization. Unannotated functions are refused rather than
silently checked using function-wide storage lifetimes.

Full Rust move semantics, C++ destructor interpretation, container invalidation, interior
mutability and cross-function region inference are not implemented. Exception handling is checked
through EDG's `try` protocol ("try and catch"), not through cleanup edges of its own.
`rref-arg` does not mean that an ordinary C++ moved-from value is dead.

## Rust frontend boundary

Rust programs are checked through mrustc's monomorphised MIR: `scripts/mrustc-borrowck.sh prog.rs`
runs mrustc, `scripts/monomir-to-pathb.rb --borrow`, and this checker with `--infer-loan-ends` and
`--infer-summaries`. [mrustc-borrowck.md](mrustc-borrowck.md) describes the facts it emits, the
verdicts mrustc gives itself, and `tests/mrustc-borrow`, which records rustc's verdict for each
case. Generic bodies are checked only as the instances a program uses. Moves of non-Copy places
are `move-value`s; drop obligations for them are not emitted.

`(readonly %N)` is the one fact only that translator emits: parameter `%N` is a pointer the function
does not write through (a Rust `&T`). Summary inference gives it read-only modes.

## Tests

Run `tests/pathb-borrow/run.sh`. The suite checks exact diagnostics and exit statuses on hand-written
IR, and checks real C++ lowering for accepted code, partial initialization, and dangling pointers.
The C++ IR must also remain accepted by the QBE emitter. Tests include branch joins, pointer aliases,
backedges, zero-iteration loops, redeclarations, local-address returns, and explicit refusals.
Paired fixtures in `tests/pathb-borrow/inferred` check both explicit and inferred results, including
last-use release, future-use conflicts, branch-specific release, backedges, stored pointers, and
parent/child demands. Refusal cases are also run with inference enabled. Value-transfer fixtures
run in both loan modes and cover moved-state joins, reinitialization,
consuming pointer carriers, and conflicts with live loans. Field-range fixtures cover partial
moves, byte repairs, overlapping loans, projected reborrows, pointer-field provenance, storage
reuse, and conservative padding checks. Semantic-layout fixtures verify field-only initialization,
nested layouts, moved fields, raw padding reads, storage lifetimes, and malformed descriptor graphs.
Drop-state fixtures check conditional flags, double consumption, missing cleanup, construction
registration, field ownership, typed transfers, reconstruction, and live-loan conflicts.
Call fixtures cover preconditions, aliasing, scalar signatures, initialization, ownership
consumption, stored-pointer lifetimes, and padding/provenance invalidation. Returned-loan fixtures
cover root/parent identities, field ranges, permissions, scope and parent expiry, malformed
contracts, and inferred last-use release.
Two-phase fixtures, `cases/loan_two_phase_*` and `inferred/two_phase_receiver`, cover reads while
reserved, a shared loan live at activation, a write or an exclusive loan while reserved, and
activation on one branch.
Implicit-loan fixtures in `tests/pathb-borrow/inferred/implicit_*` cover last use, future
conflicts, dangling results, and loops, in both loan modes.
Two-source fixtures (`inferred/implicit_two_sources_*`, `returned/two_*`, `verify/alias_two_*`,
`summaries/alias_two_*`) cover a write to either source while the result is live, a source that dies
first, a write through a two-field result, overlapping sources, `call-borrow`, a body that returns
an undeclared range, and inference of both shapes. `contracts/two_sources.cpp` infers both shapes
from lowered C++, reports a conflict for a write to the second argument or the second field while
the result is held, and runs natively.
Summary-inference fixtures in `tests/pathb-borrow/summaries` cover each inferred effect,
alias offsets and permissions, recursion, caller misuse, and functions left without a summary. A
lowered C++ program is checked with inferred summaries, and fails once its initializing call is
removed.
`tests/pathb-borrow/contracts/layouts.cpp` checks a reader of a padded nested struct through the
frontend's layout records and is refused once they are removed, with identical QBE either way.
`nolayouts.cpp` lists struct shapes that must get no record.
Copy fixtures in `tests/pathb-borrow/copy` cover loans over either side, external sources,
escaping copies, and copies from ended storage. The C++ cases `cpp/copy_*.cpp` carry an
uninitialized field and a dangling pointer field through struct copies, and `cpp/byval_*.cpp`
check a by-value parameter's copy and a returned address of it.
`contracts/byval.cpp` passes a struct by value through an inferred `(byval T)` summary, finds an
uninitialized field in the caller's copy, and runs natively. The fixtures `calls/byval_*.ir` cover
an uninitialized argument and a by-value contract passed by address, and `calls/byval_deep*.ir`
a `byval-deep` argument whose stored reference stays borrowed until the call or dangles at it.
`contracts/longdouble.cpp` checks `long double` and `__int128` arithmetic through the runtime
summaries. It is refused without them and finds an uninitialized operand at the helper call. A
module's own summary overrides the file's. The emitter and oracle accept every summary in the
file, and the program runs natively.
`contracts/raii.cpp` checks a local with a destructor, its exception-stack frames, and the
destructor's inferred summary, and runs natively. A variant that uses the object through a pointer
after its scope reports `use-after-scope`. The fixtures in `tests/pathb-borrow/eh` cover push and
pop, frames left pushed on some path, a pop after the frame's scope, unknown entries, and
scalar and escaping stores to globals.
`contracts/const_alias.cpp` infers a shared summary for a `const int *` result. A variant that
writes the source while holding the result reports `loan-conflict`. The fixtures
`returned/const_*.ir` cover the shared, conflicting, and refused exclusive forms.
Array-indexing fixtures in `tests/pathb-borrow/index` cover dynamic reads, weak writes, loans and
shared loans of arrays, use after scope, and refusals. The C++ cases `cpp/array_*.cpp` check a
range-based `for`, an indexed loop, an uninitialized element, and a dangling array pointer.
Verified-summary fixtures cover each argument effect, nested and recursive contracted calls,
argument reborrows, returned alias offsets and permissions, closed and noescape violations,
missing outputs or consumption, and malformed signatures.
A native test checks both the unchanged QBE and the stricter conservative result when metadata is
removed. The explicit-loan and
reborrow cases cover permissions, overlapping loans, copies, branch joins,
loop iterations, parent restoration, nested children, shared siblings, and invalid parent graphs. A native execution check verifies that loan metadata erasure leaves the QBE output
unchanged and that the emitter agrees with its oracle. The Path B CI workflow runs this suite
alongside the stage 1/2 tests.
