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
(scope-end $"x")         local storage lifetime ends
(rref-arg $"x")          C++ rvalue-reference argument; requires future move contracts
```

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
accesses at the join. Local names and internal provenance tokens occupy distinct namespaces.

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
use-after-scope. Source locations and language-level region contracts remain future work.

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
of calls remain unsupported. Neither frontend emits these forms yet.

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
layouts, dynamic offsets/indices, out-of-bounds accesses, external pointer projections, and accesses
outside a loan's range. Aggregate value loads/transfers remain refused. Without semantic metadata,
whole-object loan widths come from the matching root slot. With the metadata below, nested aggregate
widths come from validated descriptors. Unknown nested widths are refused. Constant offset forms are accepted as address operands by both QBE emitters as well as in ordinary
three-address IR, and explicit projected moves/copies lower to the same typed loads.

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
struct, and field types determine widths and alignment. Scalars, pointers, and other declared struct
layouts are supported. Pointers do not recursively embed their pointee, so self-referential pointer
types are valid. By-value cycles, missing nested layouts, duplicate fields/layouts, and out-of-bounds
fields are errors. Overlapping or unaligned fields, arrays, and union descriptors are refused.
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
type. Neither frontend emits these records or ownership loan/transfer forms yet. Source-language
drop, active-member, and trait rules remain separate work.

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

`nothrow` excludes exceptional continuations. `noescape` promises that argument addresses are not
retained beyond the call, except for an explicitly declared returned alias. `closed` promises no access to globals, hidden pointees, or other externally
visible memory outside the declared argument regions; private callee-local storage is permitted.
These are trusted imports, not facts inferred from names or checked against callee implementations.
The producer must ensure the real callee satisfies the summary. Functions defined in the IR are
still analyzed individually; checking their agreement with a summary is not implemented.

Read effects may have several possible known local targets, all of which are checked. Mutation,
initialization, and consumption require one known place. Read/read aliases are allowed; arguments
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
sources are refused. An ordinary `call` cannot discard the required returned-loan identity.

`root` requires a direct local place or constant offset. For a result derived from an existing
loan, use `(parent "P")` instead; the actual source must preserve that parent's identity and
constant offset. The result cannot upgrade shared permission, outlive the parent or referent,
or escape the checked function as a local address. Existing `loan-end` and opt-in last-use inference
apply to the returned loan and its ancestors. Field-range results protect only their returned range
after the call, while call preconditions still cover the complete argument effect region.

These contracts remain trusted: the checker does not inspect the callee to prove where its pointer
actually points. Heap-owned returns, aliases selected from several arguments, retained borrows,
generic lifetime signatures, and Rust frontend emission remain unsupported. The emitter erases
`call-borrow` to an ordinary call. A native C identity helper verifies the actual pointer return,
write through the result, byte-identical metadata erasure, and emitter/oracle agreement.

## Refusals and limits

Exit status is 0 for supported local checks passing, 1 for a detected lifetime/initialization
error, 2 for malformed IR, and 3 when analysis is unsupported. Diagnostics currently identify
functions and slots; source spans remain future work.

Calls without a supported closed effect contract are refused. So are rvalue-reference arguments,
aggregate values, dynamic indices, general pointer arithmetic, unknown pointer provenance,
external stores, and stores through multiple possible destinations. Unknown instructions are
refused. Escapes never establish initialization. Unannotated functions are refused rather than
silently checked using function-wide storage lifetimes.

Full Rust move semantics, C++ destructor interpretation, exception cleanup analysis, container
invalidation, interior mutability and cross-function region inference are not implemented.
`rref-arg` does not mean that an ordinary C++ moved-from value is dead.

## Rust frontend boundary

The facts and CFG engine are language independent, but **the monomir driver is not yet connected**.
Its current output does not preserve enough source storage boundaries and lifetime contracts.
Adding function-wide declarations alone would hide dangling references and must not be used as a
substitute. The next frontend task is to preserve storage and borrow facts from mrustc MIR before
lowering erases them. Full Rust conformance also requires checking generic bodies before
monomorphization, including bodies not instantiated by a program.

The next steps are frontend layout/ownership emission, callee-summary verification, general returned and
retained reference relationships, cleanup edges, and source locations. They should be added with a must-accept/must-reject pair for each rule.

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
A native test checks both the unchanged QBE and the stricter conservative result when metadata is
removed. The explicit-loan and
reborrow cases cover permissions, overlapping loans, copies, branch joins,
loop iterations, parent restoration, nested children, shared siblings, and invalid parent graphs. A native execution check verifies that loan metadata erasure leaves the QBE output
unchanged and that the emitter agrees with its oracle. The Path B CI workflow runs this suite
alongside the stage 1/2 tests.
