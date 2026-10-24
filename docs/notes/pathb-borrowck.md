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

## Refusals and limits

Exit status is 0 for supported local checks passing, 1 for a detected lifetime/initialization
error, 2 for malformed IR, and 3 when analysis is unsupported. Diagnostics currently identify
functions and slots; source spans remain future work.

Calls require effect/lifetime contracts and are refused. So are rvalue-reference arguments,
aggregate values, field/index projections, pointer arithmetic, unknown pointer provenance,
external stores, and stores through multiple possible destinations. Unknown instructions are
refused. Escapes never establish initialization. Unannotated functions are refused rather than
silently checked using function-wide storage lifetimes.

No mutable/shared loan conflict checks, Rust moves, C++ destructor interpretation, exception
cleanup analysis, container invalidation, interior mutability, or cross-function region inference
are implemented. `rref-arg` does not mean that an ordinary C++ moved-from value is dead.

## Rust frontend boundary

The facts and CFG engine are language independent, but **the monomir driver is not yet connected**.
Its current output does not preserve enough source storage boundaries and lifetime contracts.
Adding function-wide declarations alone would hide dangling references and must not be used as a
substitute. The next frontend task is to preserve storage and borrow facts from mrustc MIR before
lowering erases them. Full Rust conformance also requires checking generic bodies before
monomorphization, including bodies not instantiated by a program.

The next shared-IR extensions are explicit move/copy and shared/exclusive loan operations,
field-sensitive places, call effects, signature lifetime relationships, cleanup edges, and source
locations. They should be added with a must-accept/must-reject pair for each rule.

## Tests

Run `tests/pathb-borrow/run.sh`. The suite checks exact diagnostics and exit statuses on hand-written
IR, and checks real C++ lowering for accepted code, partial initialization, and dangling pointers.
The C++ IR must also remain accepted by the QBE emitter. Tests include branch joins, pointer aliases,
backedges, zero-iteration loops, redeclarations, local-address returns, and explicit refusals.
The Path B CI workflow runs this suite alongside the stage 1/2 tests.
