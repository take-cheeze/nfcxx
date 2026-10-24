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
place and creates a loan whose ID is unique within the function. Pointer copies, stores, loads,
and pointer casts preserve that identity. The QBE emitter evaluates `borrow` as its address
operand and emits no code for `loan-end`; both the emitter and its oracle validate their shape.

A shared loan permits reads and prevents writes to its referent. An exclusive loan prevents
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
reinitializes it. A move conflicts with every live loan of the source, including shared loans.
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
are not claims that moving a Rust integer makes it unusable. Transfers currently require whole,
direct local scalar/pointer slots. Aggregates, partial moves, indirect moves, drops, and
ownership effects of calls remain unsupported. Neither frontend emits these forms yet.

C++ `rref-arg` is still refused: an rvalue-reference argument alone does not authorize treating the
source as dead. Ordinary C++ moved-from objects can remain usable; their contracts need separate
modeling before a frontend can emit a consuming transfer.

## Refusals and limits

Exit status is 0 for supported local checks passing, 1 for a detected lifetime/initialization
error, 2 for malformed IR, and 3 when analysis is unsupported. Diagnostics currently identify
functions and slots; source spans remain future work.

Calls require effect/lifetime contracts and are refused. So are rvalue-reference arguments,
aggregate values, field/index projections, pointer arithmetic, unknown pointer provenance,
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

The next shared-IR extensions are field-sensitive places, partial moves, drops, call
effects, signature lifetime relationships, cleanup edges, and source locations. They should be added with a must-accept/must-reject pair for each rule.

## Tests

Run `tests/pathb-borrow/run.sh`. The suite checks exact diagnostics and exit statuses on hand-written
IR, and checks real C++ lowering for accepted code, partial initialization, and dangling pointers.
The C++ IR must also remain accepted by the QBE emitter. Tests include branch joins, pointer aliases,
backedges, zero-iteration loops, redeclarations, local-address returns, and explicit refusals.
Paired fixtures in `tests/pathb-borrow/inferred` check both explicit and inferred results, including
last-use release, future-use conflicts, branch-specific release, backedges, stored pointers, and
parent/child demands. Refusal cases are also run with inference enabled. Value-transfer fixtures
run in both loan modes and cover moved-state joins, reinitialization,
consuming pointer carriers, and conflicts with live loans. The explicit-loan and
reborrow cases cover permissions, overlapping loans, copies, branch joins,
loop iterations, parent restoration, nested children, shared siblings, and invalid parent graphs. A native execution check verifies that loan metadata erasure leaves the QBE output
unchanged and that the emitter agrees with its oracle. The Path B CI workflow runs this suite
alongside the stage 1/2 tests.
