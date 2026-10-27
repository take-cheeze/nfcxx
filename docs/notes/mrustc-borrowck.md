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
     external. Those in `scripts/monomir-std.rb` get trusted summaries (below); a call to any other
     has no summary, and the caller is refused.
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

## Standard library calls

`scripts/monomir-std.rb` is a table of trusted summaries keyed by mrustc's monomorphised path
(`<alloc::vec::Vec<i32,alloc::alloc::Global>>::push`, after normalising away crate versions and
lifetimes). The translator emits a `call-effects` form for each called function that matches. A
summary says what the borrow checker needs, and a panic aborts (mrustc links `panic_abort`), so none
may throw:

- **`Vec<T>`**: `new`, `with_capacity` (initialize the result); `push`, `pop`, `clear`, `truncate`
  (`write` the Vec); `len`, `is_empty`, `capacity` (`read`); `Index::index` and
  `IndexMut::index_mut`, whose result is a returned alias at offset 0 of the Vec, shared or exclusive.
  The elements are on the heap, which the checker does not track, so a reference to one is modelled
  as one into the Vec itself, with the Vec's loan: the loan rustc gives it too. Drop glue is a `write`
  of the Vec, which conflicts with any loan of it still live.
- **`Box<T>`**: `new` and drop glue. The translator treats a Box as holding its value in its own place:
  mrustc's `*b.0 .0 .0` is the Box's address, so `&*b` is a loan of `b`, as in rustc.
- **`Range<T>`** `into_iter` and `next`, and **`Option<T>`** `unwrap`, `is_some`, `is_none` (`for i in
  0..n`). An Option of a scalar holds no pointer; it gets a layout of one byte array.
- **Formatting**. `fmt::rt::Argument::new_display` (and `new_debug`, `new_lower_hex` and the other
  specs) and `fmt::Arguments::new_v1` and `new_const` keep the references they are given, which a
  summary cannot say. The translator replaces each call with the stores of those references into the
  result, as the constructor's body does, and the checker tracks them like other stored references.
  `_print` and `_eprint` take the Arguments with `(byval-deep T)`, which also reads what the value's
  pointers reach ([pathb-borrowck.md](pathb-borrowck.md)), so a reference that dangles or is mutably
  borrowed when it is printed is an error, and the loans the Arguments holds stay live until then.
  mrustc ends the storage of format_args!'s array of `Argument`s before the Arguments that points to
  it is used; the translator keeps that array's storage to the end of the function.

Containers are covered only for primitive scalar elements: such an element holds no reference, so a
Vec or Box of one keeps no borrow and its drop reads only its own place. A Vec of references, `vec![]`
(`Box<[T]>`), slices (`&[T]` is a two-word value, which a summary cannot return), iterators,
`String`, and a user `impl Display` (it calls `Formatter` methods) have no summaries and are refused.

mrustc also rejects some programs itself, and the driver reports those as errors (exit 1):

- `mrustc-mir-validation:`, from mrustc's MIR validation. It tracks which locals hold a value, so it
  rejects a use after a move (E0382) and a read of a possibly uninitialized local (E0381). mrustc stops
  with an internal error there, not a diagnostic.
- `mrustc-lifetime:`, from mrustc's lifetime inference, which rejects a returned reference to a local
  (E0515).

## Results

`tests/mrustc-borrow/cases` has one program per rule, each with rustc 1.99's verdict. The suite
checks this pipeline's verdict, and compares rustc's when one is installed. 24 of the 30 cases agree
with rustc:

| Verdict | Cases |
| --- | --- |
| Accepted, as by rustc | scoped `&mut` then `&`, NLL last use, repeated `&mut` calls, disjoint field borrows, loop-body locals, returned field reference, conditional return of a borrow, println!/eprintln! with format specs, Vec push/pop/len/index/index_mut over a range loop, Box reads and writes |
| Rejected, as by rustc | E0499 two `&mut`, E0502 (twice), E0506, E0597 dangling, E0381 and E0382 (mrustc), E0515 (mrustc); with std calls: E0502 push while an element is borrowed, `&mut v[0]` while `&v[1]` is live, println! while `&mut x` is live; E0506 a write through a borrowed Box, a held `format_args!`; E0597 an element reference that outlives its Vec |
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
- **A Vec of references** is refused: its functions have summaries only for scalar elements.

Generic functions are checked only as the instances the program uses, after monomorphisation.
Standard library calls outside the table above are refused for lack of summaries. Interior mutability (`Cell`, `RefCell`) is not modelled: a write through a
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
- More standard library summaries: slices and iterators need fat-pointer results, `String` and
  containers of references need summaries that keep borrows.
- Results that borrow from several sources, which needs region parameters in summaries.
