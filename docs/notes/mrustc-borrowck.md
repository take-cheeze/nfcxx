# Borrow-checking Rust through mrustc's MIR

mrustc compiles Rust without checking borrows. This route borrow-checks a program's own functions
with nfcxx's Path B checker ([pathb-borrowck.md](pathb-borrowck.md)), reading the MIR that mrustc's
monomir backend dumps ([mrustc-monomir.md](mrustc-monomir.md)):

```sh
scripts/mrustc-borrowck.sh prog.rs          # exit 0 accepted, 1 error, 3 refused, 4 tool failure
MRUSTC_BORROWCK_KEEP=out scripts/mrustc-borrowck.sh prog.rs   # keeps out/prog.mir and out/prog.ir
tests/mrustc-borrow/run.sh
```

The pipeline is:

1. **mrustc** with `MRUSTC_MMIR_SCOPE_END=1` and `-Z disable-mir-opt`, writing the monomir dump.
   The pinned mrustc (`scripts/setup-mrustc.sh`, branch `nfcxx/borrowck-scope-end`) has two changes
   for it. The MIR builder emits `ScopeEnd` statements again (their emission was disabled), and the
   dump prints them as `SCOPEEND var3 var4;`: the points where locals' storage ends. And
   `-Z disable-mir-opt` also turns off the inlining and optimisation after monomorphisation, which
   ran regardless and could delete a borrow whose result is unused. Without the variable and the
   flag, mrustc's output is unchanged.
2. **`scripts/monomir-to-pathb.rb --borrow`**, which writes checker input instead of code:
   - Only the program's own functions (`bin#` paths) get bodies. Standard library functions stay
     external, so a call to one has no summary and the caller is refused.
   - Locals are not zero-filled, so reads before initialization stay visible. Zero-sized locals get
     no slot.
   - `SCOPEEND` becomes `(scope-end $"varN")`. MIR has no statement for the start of storage, so a
     dataflow over the blocks puts a `(decl $"varN" val|ref)` before the first write to a local that
     no path into that point has started. A loop body's locals start again on each iteration. mrustc
     ends a condition temporary's storage just before the `IF` or `SWITCH` that reads it, so those
     ends are emitted after the read.
   - `&place` and `&mut place` of a local place reached without a deref (fields and enum variants
     included) become `(borrow (ptr T) "Ln" shared|exclusive PLACE)`. A borrow through a deref is a
     plain address and carries the loans of the pointer it derefs, so a reborrow has no loan of its own.
   - A `&T` parameter gets `(readonly %N)`, which keeps summary inference to read-only modes. The
     signature's `&` against `&mut` is the information the checker would otherwise not have.
   - `(borrow-layout ...)` records for the structs the functions use come from the dump's `type`
     records. Enums (overlapping variants) get none.
3. **`scripts/pathb-borrowck.rb --infer-loan-ends --infer-summaries`**. Loans end at their last use
   (NLL's rule), and each function gets a summary inferred from its body, which its callers are
   checked against.

mrustc also rejects some programs itself, and the driver reports those as errors (exit 1):

- `mrustc-mir-validation:`, from mrustc's MIR validation. It tracks which locals hold a value, so it
  rejects a use after a move (E0382) and a read of a possibly uninitialized local (E0381). mrustc stops
  with an internal error there, not a diagnostic.
- `mrustc-lifetime:`, from mrustc's lifetime inference, which rejects a returned reference to a local
  (E0515).

## Results

`tests/mrustc-borrow/cases` has one program per rule, each with rustc 1.99's verdict. The suite
checks this pipeline's verdict, and compares rustc's when one is installed. 15 of the 20 cases agree
with rustc:

| Verdict | Cases |
| --- | --- |
| Accepted, as by rustc | scoped `&mut` then `&`, NLL last use, repeated `&mut` calls, disjoint field borrows, loop-body locals, returned field reference, conditional return of a borrow |
| Rejected, as by rustc | E0499 two `&mut`, E0502 (twice), E0506, E0597 dangling, E0381 and E0382 (mrustc), E0515 (mrustc) |
| Different | below |

The differences are the known gaps:

- **Move while borrowed (E0505) is accepted.** The translator lowers a move as a copy, and mrustc's
  validation only sees the moved-from local itself, not the borrow's use. Explicit `move-value`
  forms (pathb-borrowck.md, "Explicit value moves and copies") are the next step.
- **Two-phase borrows** (`c.set(c.get() + 1)`) give a false `loan-conflict`. rustc reserves the
  receiver's `&mut` and activates it after the arguments. The checker takes the exclusive loan first.
- **A result that may borrow from either of two arguments, or two fields** (`pick(&x, &y)`, NLL's
  "problem case 3", which rustc 1.99 accepts) is refused. A summary names one source range, and
  with lifetimes erased the translator cannot say that the result borrows from both.
- **A borrow stored across loop iterations** (E0499) is refused: a store through a pointer with
  joined provenance is outside the subset.

Generic functions are checked only as the instances the program uses, after monomorphisation.
Standard library calls are refused for lack of summaries, which limits the route to small
programs for now. Interior mutability (`Cell`, `RefCell`) is not modelled: a write through a
shared borrow is an error.

## How this compares with other implementations

As of October 2026:

- **rustc** checks borrows on its own MIR, before optimisation and on generic bodies, with NLL. Its
  next checker, Polonius alpha (location-sensitive), was enabled on nightly in August 2026. Full
  Polonius remains future work. This route follows the same model as NLL on a lower level IR:
  storage ends, loans, and liveness-based loan ends. Its input is monomorphised and has lost lifetimes
  and two-phase borrows.
- **gccrs** lowers to its own borrow-checker IR (BIR), generates Polonius facts from it, and runs the
  Polonius library. That is the same arrangement as here: a frontend's IR, then a separate checker.
  It reached GCC 15 in 2025.
- **mrustc** has no borrow checker; `src/mir/borrow_check.cpp` is a skeleton. Its MIR validation
  and lifetime inference catch moves, uninitialized reads and some returned references, as above.
- **Clang's lifetime safety analysis** (`-fexperimental-lifetime-safety`) is an intra-procedural,
  Polonius-inspired analysis of loans over Clang's CFG for C++ pointers. It is designed for finding
  bugs, with warnings, not as a verifier. This checker refuses what it cannot prove instead.

## Next steps

- Moves: `move-value` for moved operands, then drop obligations for types with drop glue.
- Two-phase borrows: a reserved state for the receiver's loan until the call.
- Summaries for the standard library functions small programs use (formatting, `Vec`, `Box`).
- Results that borrow from several sources, which needs region parameters in summaries.
