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
   flag, mrustc's output is unchanged. `-Z dump-hir` also writes the crate's HIR, for its
   `impl Copy` items, and `-Z dump-ast` the expanded AST, for its explicit `&mut` arguments (below).
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
   - A `&mut` of such a place is `two-phase` instead of `exclusive` when its local is assigned only
     there and its one other mention is as the first argument of a `CALL` to a path: the shape of an
     autoref'd method receiver and of an overloaded `+=`'s left side, rustc's two-phase borrows. The
     checker treats it as shared until the call and exclusive from there (pathb-borrowck.md,
     "Two-phase loans"). A `&mut` variable does not match, since mrustc passes it as a reborrow
     `&mut (*varN)`. An explicit `&mut x` first argument or receiver matches too, and the MIR and the
     final HIR (where method calls are already paths with their autorefs) cannot tell it from an
     autoref. The expanded AST (`--ast`) still can: the functions it calls with a written `&mut` as
     first argument are collected by name (a `&mut` elsewhere in an expression names every function
     called on its line), and a call whose mangled callee holds one of those names gets no two-phase
     borrow. Without `--ast`, none is two-phase.
   - A move of a local place of a non-Copy type (a use, an aggregate's operand, or a call argument)
     is marked after the statement that reads it (pathb-borrowck.md, "Explicit value moves and
     copies"). The `copy` that an ASSIGN reads an aggregate with becomes `(move N DST SRC)`, which
     moves its bytes and its drop obligations to DST; a call's by-value argument is followed by
     `(move N SRC)`; a scalar (a `&mut`) by `(eval (move-value T PLACE))`. The checker then rejects
     a move with a live loan of the place (E0505). The dump prints a move and a copy alike, so the
     translator decides: a type moves if it has drop glue, is a `&mut`, or is one of the program's
     types with no `impl Copy` in the HIR (`--hir`); tuples and arrays follow their elements. A type
     that holds an `UnsafeCell` (`Cell`, `RefCell`) moves too, since it cannot be Copy. Other
     types count as Copy, which can miss a move but not report a false one. Enum fields, moves
     through a deref or out of an enum variant, and fat pointers get no marks.
     types with no `impl Copy` in the HIR (`--hir`); tuples and arrays follow their elements. Other
     types count as Copy, which can miss a move but not report a false one. Enums move as bytes,
     tag and payload, and a move out of a variant (`m@0 .0`) as the payload's bytes. Fat pointers
     get no marks. A move through a deref is not marked: Rust allows one only out of a Box, and a
     Box of a non-scalar is refused (below), while a Box of a scalar holds a Copy value.
   - A local or by-value parameter whose type has drop glue gets `(drop-obligation ID T PLACE)`
     facts (pathb-borrowck.md, "Explicit drop-state contracts"): one for a standard library type
     with drop glue or a program type with an `impl Drop` (the HIR's), and for a program struct or a
     tuple without one, one per field with drop glue (`var0.1`), since mrustc moves and drops those
     separately. A program type with an `impl Drop` is `deep`: its drop may use the references the
     value holds (rustc's E0597 for a Drop type that outlives a borrowed local). The value is
     registered (`drop-live`) after the ASSIGN or CALL that writes it whole, and a by-value
     parameter at entry. mrustc elaborates drops itself: a moved value has no DROP, and one moved on
     some paths is dropped under a drop flag (`DROP var0 IF df0`). `DROP` of a place holding
     obligations becomes `drop-state` for each, under a flag `drop-state-if-live`, which consumes
     the paths where the value is still live; the checker does not correlate the flag with them, so
     this trusts mrustc's flags. The checker then rejects a use after the drop, a drop after a move,
     a drop with a live loan of the value, and a return or storage end that leaves one owed. A value
     that is moved out of in part is refused when it has an `impl Drop` (E0509, which mrustc does not
     check), since its move stays a `copy` of part of the obligation.
   - Enums get no obligation. They have no layout, and mrustc's drop elaboration does not drop a
     match scrutinee that one arm moves out of, on any arm (`match o { Some(v) if c => take(v), _ =>
     0 }` leaks `v` when `c` is false), so an obligation would report mrustc's leak. A DROP of an
     enum stays a call of its drop glue, which has no summary (the program's enums' glue gets no
     body), so it is refused; a program that moves its enums out is checked. A value without a
     layout (a struct with an enum field) gets none either, and its DROPs stay drop glue calls.
   - A `&T` parameter gets `(readonly %N)`, which keeps summary inference to read-only modes. The
     signature's `&` against `&mut` is the information the checker would otherwise not have.
   - `(borrow-layout ...)` records for the structs the functions use come from the dump's `type`
     records. Enums (overlapping variants) get none. Each `UnsafeCell<T>` with a record also gets
     `(interior-mutable (struct ...))` (below, "Interior mutability").
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
  of the Vec, which conflicts with any loan of it still live; a local Vec's drop is its obligation's
  `drop-state` instead, which conflicts the same way.
- **`Box<T>`**: `new` and drop glue. The translator treats a Box as holding its value in its own place:
  mrustc's `*b.0 .0 .0` is the Box's address, so `&*b` is a loan of `b`, as in rustc.
- **`Range<T>`** `into_iter` and `next`, and **`Option<T>`** `unwrap`, `is_some`, `is_none` (`for i in
  0..n`). An Option of a scalar holds no pointer; it gets a layout of one byte array.
- **`mem::drop` and `mem::forget`** of a struct take it by value and keep nothing. The value is
  moved into the call, so the caller owes no drop of it.
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

### Interior mutability

The bytes of an `UnsafeCell<T>` may be written through a shared reference. The translator marks each
`UnsafeCell` type `(interior-mutable ...)`, and the checker accepts a write through a shared loan into
those bytes only when it leaves the checker's state unchanged: a scalar written over initialized bytes
that hold no pointer (pathb-borrowck.md, "Interior mutability"). Everything the checker concluded from
the loan being shared therefore still holds, including a `read` summary of a `&T` parameter, so
`(readonly %N)` needs no exception for the cell's bytes. As for containers, only cells of primitive
scalars have summaries:

- **`Cell<T>`**: `new`, `get`, `into_inner`; `set`, `replace`, `take`, whose `&self` argument is a
  `write` the checker accepts through a shared loan; `get_mut`, a returned exclusive alias of `&mut self`.
  Cell hands out no other reference into itself, so nothing can point at the value it overwrites.
- **`RefCell<T>`**: `new`, and `replace` (a `write`). `borrow` and `borrow_mut` become, as the
  formatting constructors do, the stores of the guard's two references into the RefCell (its value and
  its borrow flag), plus a read and write of the flag through the shared reference for the dynamic
  check. The guard therefore keeps the RefCell borrowed while it is used, and its drop glue, which reads
  and writes the flag through its reference, is such a use: a guard that outlives its RefCell is an
  error (E0597), and moving the RefCell while a guard is live is E0505. Two guards at once are left to
  RefCell's runtime check, as rustc does.
- **`Ref::deref`** and **`RefMut::deref`** return `&T`, which is modelled as a reference into the guard,
  with the loan of the guard that deref takes: the loan rustc gives it. **`RefMut::deref_mut`** loads the
  value's reference from the guard, because a `&mut T` is written through; it keeps the RefCell's loan.

`try_borrow`, `Ref::map`, `Rc<RefCell<T>>`, atomics, and cells of anything but a primitive scalar have
no summaries and are refused.

mrustc also rejects some programs itself, and the driver reports those as errors (exit 1):

- `mrustc-mir-validation:`, from mrustc's MIR validation. It tracks which locals hold a value, so it
  rejects a use after a move (E0382) and a read of a possibly uninitialized local (E0381). mrustc stops
  with an internal error there, not a diagnostic.
- `mrustc-lifetime:`, from mrustc's lifetime inference, which rejects a returned reference to a local
  (E0515).

## Results

`tests/mrustc-borrow/cases` has one program per rule, each with rustc 1.99's verdict. The suite
checks this pipeline's verdict, and compares rustc's when one is installed. 49 of the 52 cases agree
checks this pipeline's verdict, and compares rustc's when one is installed. 44 of the 47 cases agree
checks this pipeline's verdict, and compares rustc's when one is installed. 51 of the 54 cases agree
with rustc:

| Verdict | Cases |
| --- | --- |
| Accepted, as by rustc | scoped `&mut` then `&`, NLL last use, repeated `&mut` calls, disjoint field borrows, loop-body locals, returned field reference, conditional return of a borrow, two-phase receiver (`c.set(c.get() + 1)`), move after the borrow's last use, Copy value passed while borrowed, a result borrowing from either of two arguments, NLL problem case 3 (either of two fields), a write through a reference to either of two locals, println!/eprintln! with format specs, Vec push/pop/len/index/index_mut over a range loop, Box reads and writes, Cell set/get through two shared references, `&self` and `&Cell` functions that write a Cell, RefCell borrow_mut and borrow through `&self` methods, a Ref and a RefMut at once (runtime-checked) |
| Rejected, as by rustc | E0499 two `&mut`, E0499 a borrow kept across loop iterations, E0502 (twice), E0505 move while borrowed, E0506 (three times: a plain borrow, and a write to the second argument or the second field of a two-source result), E0597 dangling (twice, once through a two-source result), E0381 and E0382 (mrustc), E0515 (mrustc); with a two-phase receiver, a write to its place (E0506) or another `&mut` receiver (E0499) in the arguments, and a shared borrow live at the call (E0502); with std calls, E0502 push while an element is borrowed, `&mut v[0]` while `&v[1]` is live, println! while `&mut x` is live, E0506 a write through a borrowed Box and a held `format_args!`, E0597 an element reference that outlives its Vec; with cells, E0505 a Cell moved and a RefCell moved while borrowed, E0506 a Cell assigned while borrowed, E0502 Cell::get_mut while borrowed, E0597 a Ref or RefMut guard that outlives its RefCell and a Ref's `&T` that outlives the guard |
| Accepted, as by rustc | scoped `&mut` then `&`, NLL last use, repeated `&mut` calls, disjoint field borrows, loop-body locals, returned field reference, conditional return of a borrow, two-phase receiver (`c.set(c.get() + 1)`, `v.push(v.len())`) and overloaded `+=` (`c += c.get()`), move after the borrow's last use, Copy value passed while borrowed, a result borrowing from either of two arguments, NLL problem case 3 (either of two fields), a write through a reference to either of two locals, println!/eprintln! with format specs, Vec push/pop/len/index/index_mut over a range loop, Box reads and writes |
| Rejected, as by rustc | E0499 two `&mut`, E0499 a borrow kept across loop iterations, E0502 (twice), E0505 move while borrowed, E0506 (three times: a plain borrow, and a write to the second argument or the second field of a two-source result), E0597 dangling (twice, once through a two-source result), E0381 and E0382 (mrustc), E0515 (mrustc); with a two-phase receiver, a write to its place (E0506) or another `&mut` receiver (E0499) in the arguments, and a shared borrow live at the call (E0502, also for `+=`); E0502 for an explicit `&mut c` first argument, receiver, or `AddAssign::add_assign(&mut c, ..)`, which are not two-phase; with std calls, E0502 push while an element is borrowed, `&mut v[0]` while `&v[1]` is live, println! while `&mut x` is live, E0506 a write through a borrowed Box and a held `format_args!`, E0597 an element reference that outlives its Vec |
| Accepted, as by rustc | scoped `&mut` then `&`, NLL last use, repeated `&mut` calls, disjoint field borrows, loop-body locals, returned field reference, conditional return of a borrow, two-phase receiver (`c.set(c.get() + 1)`), move after the borrow's last use, Copy value passed while borrowed, a result borrowing from either of two arguments, NLL problem case 3 (either of two fields), a write through a reference to either of two locals, println!/eprintln! with format specs, Vec push/pop/len/index/index_mut over a range loop, Box reads and writes; with drops, a Vec moved on one branch (a drop flag), a field of a struct moved on one branch, a struct with a Drop impl and a write to its field, the same struct holding a dangling reference without the impl, reassigning a live Vec, `mem::forget` and `mem::drop`, a Vec moved into and out of an enum variant |
| Rejected, as by rustc | E0499 two `&mut`, E0499 a borrow kept across loop iterations, E0502 (twice), E0505 move while borrowed, E0506 (three times: a plain borrow, and a write to the second argument or the second field of a two-source result), E0597 dangling (twice, once through a two-source result), E0381 and E0382 (mrustc), E0515 (mrustc); with a two-phase receiver, a write to its place (E0506) or another `&mut` receiver (E0499) in the arguments, and a shared borrow live at the call (E0502); with std calls, E0502 push while an element is borrowed, `&mut v[0]` while `&v[1]` is live, println! while `&mut x` is live, E0506 a write through a borrowed Box and a held `format_args!`, E0597 an element reference that outlives its Vec; with drops, E0597 a reference into a dropped Box and a struct with a Drop impl that outlives a borrowed local, E0505 a conditional move and a `drop(v)` while borrowed, a whole-enum move and a move out of a variant while borrowed |
| Different | below |

The differences are the known gaps:

- **A callee also called with an explicit `&mut`** gets no two-phase receivers anywhere in the
  program, since calls are matched to the AST only by name: `C::set(&mut c, 2); c.set(c.get())` is
  rejected (`gap_two_phase_same_name`). This only rejects more.
- **mrustc evaluates an index before IndexMut's `&mut v`**, where rustc takes the borrow first (it is
  not two-phase), so `v[v.len() - 1] = 7` (E0502) is accepted (`gap_index_mut_order`). The index
  only reads `v` before the borrow, so the program is still memory-safe.
- **A Vec of references** is refused: its functions have summaries only for scalar elements.
- **A `&mut` from `RefMut::deref_mut` kept past its guard** (E0597) is accepted. It has the RefCell's
  loan, not one of the guard, so it stays within the RefCell's borrow and cannot dangle, but RefCell's
  runtime check no longer covers it.
- **A move out of a field of a struct with a Drop impl** (E0509) is refused rather than rejected.
  mrustc does not check the rule, and the checker sees a part of a drop obligation copied.

With lifetimes erased, the translator cannot say that `pick<'a>(a: &'a i32, b: &'a i32) -> &'a i32`
returns a borrow of either argument. Summary inference finds it instead: a summary may list several
sources (pathb-borrowck.md, "Several sources"), and inference tries the set of argument ranges the body
returns when no single one verifies. A caller keeps every source borrowed while the result is live,
which is what the shared lifetime `'a` says. The same covers NLL's problem case 3, whose result
borrows one of two fields of its `&mut` argument. A write through a reference to either of two places
is a weak update of both. In `err_loop_store` the checker rejects the use of the kept borrow after the
next iteration ends it, where rustc reports the next iteration's `&mut x`.

Generic functions are checked only as the instances the program uses, after monomorphisation.
Standard library calls outside the table above are refused for lack of summaries.
Standard library calls outside the table above are refused for lack of summaries. Interior mutability
(`Cell`, `RefCell`) is not modelled: a write through a shared borrow is an error. A drop of an
enum is refused (above).

## How this compares with other implementations

As of October 2026:

- **rustc** checks borrows on its own MIR, before optimisation and on generic bodies, with NLL. Its
  next checker, Polonius alpha (location-sensitive), was enabled on nightly in August 2026. Full
  Polonius remains future work. This route follows the same model as NLL on a lower level IR:
  storage ends, loans, and liveness-based loan ends. Its input is monomorphised and has lost lifetimes
  and the autoref marker, so two-phase borrows come from the shape of the MIR and the AST's explicit
  `&mut` arguments.
- **gccrs** lowers to its own borrow-checker IR (BIR), generates Polonius facts from it, and runs the
  Polonius library. That is the same arrangement as here: a frontend's IR, then a separate checker.
  It reached GCC 15 in 2025.
- **mrustc** has no borrow checker; `src/mir/borrow_check.cpp` is a skeleton. Its MIR validation
  and lifetime inference catch moves, uninitialized reads and some returned references, as above.
- **Clang's lifetime safety analysis** (`-fexperimental-lifetime-safety`) is an intra-procedural,
  Polonius-inspired analysis of loans over Clang's CFG for C++ pointers. It is designed for finding
  bugs, with warnings, not as a verifier. This checker refuses what it cannot prove instead.

## Next steps

- Drops of enums: a layout for the variant a path holds, and a fix (or a refusal) for mrustc's
  missing drop of a partly moved match scrutinee.
- More standard library summaries: slices and iterators need fat-pointer results, `String` and
  containers of references need summaries that keep borrows.
