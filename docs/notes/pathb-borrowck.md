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

Loan ends are **explicit**, not inferred from last use. IDs may execute repeatedly in a loop
if each iteration ends the loan before the next creation; old pointer copies remain expired.
Parent/child reborrows, field-sensitive overlap, and loans on external storage are refused until
their relationships can be represented. Ordinary C++ references do not automatically acquire
shared or exclusive loan semantics. Neither frontend emits these new forms yet.

## Refusals and limits

Exit status is 0 for supported local checks passing, 1 for a detected lifetime/initialization
error, 2 for malformed IR, and 3 when analysis is unsupported. Diagnostics currently identify
functions and slots; source spans remain future work.

Calls require effect/lifetime contracts and are refused. So are rvalue-reference arguments,
aggregate values, field/index projections, pointer arithmetic, unknown pointer provenance,
external stores, and stores through multiple possible destinations. Unknown instructions are
refused. Escapes never establish initialization. Unannotated functions are refused rather than
silently checked using function-wide storage lifetimes.

Rust moves, C++ destructor interpretation, exception cleanup analysis, container invalidation,
interior mutability, inferred non-lexical loan ends, and cross-function region inference are not
implemented. `rref-arg` does not mean that an ordinary C++ moved-from value is dead.

## Rust frontend boundary

The facts and CFG engine are language independent, but **the monomir driver is not yet connected**.
Its current output does not preserve enough source storage boundaries and lifetime contracts.
Adding function-wide declarations alone would hide dangling references and must not be used as a
substitute. The next frontend task is to preserve storage and borrow facts from mrustc MIR before
lowering erases them. Full Rust conformance also requires checking generic bodies before
monomorphization, including bodies not instantiated by a program.

The next shared-IR extensions are explicit move/copy, reborrows, field-sensitive places, call
effects, signature lifetime relationships, cleanup edges, and source locations. They should be added with a must-accept/must-reject pair for each rule.

## Tests

Run `tests/pathb-borrow/run.sh`. The suite checks exact diagnostics and exit statuses on hand-written
IR, and checks real C++ lowering for accepted code, partial initialization, and dangling pointers.
The C++ IR must also remain accepted by the QBE emitter. Tests include branch joins, pointer aliases,
backedges, zero-iteration loops, redeclarations, local-address returns, and explicit refusals.
The explicit-loan cases cover permissions, overlapping loans, copies, branch joins, and loop
iterations. A native execution check verifies that loan metadata erasure leaves the QBE output
unchanged and that the emitter agrees with its oracle. The Path B CI workflow runs this suite
alongside the stage 1/2 tests.
