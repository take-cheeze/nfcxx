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
   `impl Copy` items (below).
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
     there and its one other mention is as the first argument of a `CALL`: the shape of an autoref'd
     method receiver. The checker treats it as shared until the call and exclusive from there
     (pathb-borrowck.md, "Two-phase loans"). MIR has lost the autoref marker. A `&mut` variable does
     not match, since mrustc passes it as a reborrow `&mut (*varN)`, but an explicit `&mut x` first
     argument does.
   - A move of a local place of a non-Copy type (a use, an aggregate's operand, or a call argument)
     is followed by `(eval (move-value T PLACE))` for each scalar of the place, after the statement
     that reads it (pathb-borrowck.md, "Explicit value moves and copies"). The checker then rejects
     a move with a live loan of the place (E0505). The dump prints a move and a copy alike, so the
     translator decides: a type moves if it has drop glue, is a `&mut`, or is one of the program's
     types with no `impl Copy` in the HIR (`--hir`); tuples and arrays follow their elements. Other
     types count as Copy, which can miss a move but not report a false one. Enum fields, moves
     through a deref or out of an enum variant, and fat pointers get no marks.
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

The summaries above cover primitive scalar elements: such an element holds no reference, so a Vec
or Box of one keeps no borrow and its drop reads only its own place. A summary keeps no pointer, so
views and containers of references are table entries with *keeps* (`KEPT` in monomir-std.rb): the
call gets a summary for its accesses, and the translator follows it with stores of the pointers its
result or an argument keeps, read before the call (a call that writes its argument forgets the
pointers in it).

- **Slices and `&str`** are two words, the address of the first element and the length, with a
  layout of a pointer and an `unsigned_long`. The pointer carries the loans; the length is a scalar.
  The elements are modelled by the first, as a Vec's are by the Vec: indexing a slice is the
  slice's own pointer. A slice of a Vec points at the Vec, of an array at the array, with the loan of
  the `&` it is made from. A program function's slice parameter is passed as its two words, so its
  pointer is a parameter that summary inference describes (`(read int) (value unsigned_long)`), and a
  function returning a slice returns its pointer, inferred as a returned alias. A slice of an array
  of references would lose all but the first element's pointer, so its pointer is unknown, and a use
  is refused.
- **`Vec<T>`** `as_slice`, `as_mut_slice`, `Deref`, `DerefMut`, `<&Vec<T>>::into_iter`; **`[T]`**
  `len`, `is_empty`, `iter`, `first`, `last`, `<&[T]>::into_iter`; **`slice::Iter<T>`** `into_iter`
  and `next`, whose `Option<&T>` (one pointer) is the iterator's pointer; `Option<&T>` `unwrap`,
  `is_some`, `is_none`. The Iter holds the slice's pointer, so it keeps the slice's loans.
- **`Vec<&T>`** keeps the references pushed into it, at offset 8 of the Vec. Each push joins the new
  reference with the ones there, so every element's loans stay live while the Vec is used, as
  rustc's one lifetime for the element type does. `new`, `push`, `pop`, `len`, `is_empty`, `clear`,
  `truncate` and `Index::index` also read what the Vec holds (a byval-deep read of it), so a use of
  the Vec after an element's referent is gone is an error (E0597). Its drop glue does not: Vec's Drop
  is `#[may_dangle]`, so the references are cleared first. A write of one element would replace the
  joined references, so `index_mut`, `as_mut_slice` and `iter_mut` of a `Vec<&T>` have no entries.
- **`String`**: `new`, `push_str`, `push`, `clear`, `len`, `is_empty`, `capacity`, `clone`, `as_str`
  and `Deref` (a `&str` into the String, like a Vec's slice), drop glue, `String::from(&str)` and
  `str::to_string`, and `str::len`. A string literal's bytes are static: passing them to a program
  function reads external memory, which the checker allows for a callee it verifies
  (pathb-borrowck.md, "Closed call-effect contracts").

`vec![]` (`Box<[T]>`), subslices (`&v[1..]`), mutable iterators, containers of `&mut T` or of
structs, and a user `impl Display` (its `fmt` calls `Formatter::write_fmt` and the `?` operator's
`Try` impls) have no entries and are refused. A program function given a `&Vec<&T>` can read its
length without using the references in it, so a dangling element is found only by the caller's own
uses of the Vec.

mrustc also rejects some programs itself, and the driver reports those as errors (exit 1):

- `mrustc-mir-validation:`, from mrustc's MIR validation. It tracks which locals hold a value, so it
  rejects a use after a move (E0382) and a read of a possibly uninitialized local (E0381). mrustc stops
  with an internal error there, not a diagnostic.
- `mrustc-lifetime:`, from mrustc's lifetime inference, which rejects a returned reference to a local
  (E0515).

## Results

`tests/mrustc-borrow/cases` has one program per rule, each with rustc 1.99's verdict. The suite
checks this pipeline's verdict, and compares rustc's when one is installed. 48 of the 49 cases agree
with rustc:

| Verdict | Cases |
| --- | --- |
| Accepted, as by rustc | scoped `&mut` then `&`, NLL last use, repeated `&mut` calls, disjoint field borrows, loop-body locals, returned field reference, conditional return of a borrow, two-phase receiver (`c.set(c.get() + 1)`), move after the borrow's last use, Copy value passed while borrowed, a result borrowing from either of two arguments, NLL problem case 3 (either of two fields), a write through a reference to either of two locals, println!/eprintln! with format specs, Vec push/pop/len/index/index_mut over a range loop, Box reads and writes, slices of a Vec and of an array (`iter`, `for x in &v`, `for x in s`, indexing, `first`, `as_mut_slice`, functions taking and returning `&[i32]`), a `Vec<&i32>` pushed, indexed, iterated and popped, then its referent assigned after its last use, `String` and `&str` (literals, `push_str`, `as_str`, a function taking `&str`) |
| Rejected, as by rustc | E0499 two `&mut`, E0499 a borrow kept across loop iterations, E0502 (twice), E0505 move while borrowed, E0506 (three times: a plain borrow, and a write to the second argument or the second field of a two-source result), E0597 dangling (twice, once through a two-source result), E0381 and E0382 (mrustc), E0515 (mrustc); with a two-phase receiver, a write to its place (E0506) or another `&mut` receiver (E0499) in the arguments, and a shared borrow live at the call (E0502); with std calls, E0502 push while an element is borrowed, `&mut v[0]` while `&v[1]` is live, println! while `&mut x` is live, E0506 a write through a borrowed Box and a held `format_args!`, E0597 an element reference that outlives its Vec; with slices and containers of references, E0502 a push while iterating the Vec, while a slice returned by a function is live, and to a String while its `as_str` is live, E0506 an assignment to a referent held by a `Vec<&i32>` (pushed first of two) and inside a loop over it, E0597 a slice that outlives its Vec and a `Vec<&i32>` used after a referent's scope |
| Different | below |

The difference is a known gap:

- **An explicit `&mut x` first argument is two-phase too** (`set(&mut c, c.get())`, E0502), so it is
  accepted. rustc makes only autoref borrows two-phase, and the MIR does not say which this was. The
  program only reads `c` before the call, so the borrow is still not violated.

With lifetimes erased, the translator cannot say that `pick<'a>(a: &'a i32, b: &'a i32) -> &'a i32`
returns a borrow of either argument. Summary inference finds it instead: a summary may list several
sources (pathb-borrowck.md, "Several sources"), and inference tries the set of argument ranges the body
returns when no single one verifies. A caller keeps every source borrowed while the result is live,
which is what the shared lifetime `'a` says. The same covers NLL's problem case 3, whose result
borrows one of two fields of its `&mut` argument. A write through a reference to either of two places
is a weak update of both. In `err_loop_store` the checker rejects the use of the kept borrow after the
next iteration ends it, where rustc reports the next iteration's `&mut x`.

Generic functions are checked only as the instances the program uses, after monomorphisation.
Standard library calls outside the table above are refused for lack of summaries. Interior mutability
(`Cell`, `RefCell`) is not modelled: a write through a shared borrow is an error.

## How this compares with other implementations

As of October 2026:

- **rustc** checks borrows on its own MIR, before optimisation and on generic bodies, with NLL. Its
  next checker, Polonius alpha (location-sensitive), was enabled on nightly in August 2026. Full
  Polonius remains future work. This route follows the same model as NLL on a lower level IR:
  storage ends, loans, and liveness-based loan ends. Its input is monomorphised and has lost lifetimes
  and the autoref marker, so two-phase borrows come from the shape of the MIR.
- **gccrs** lowers to its own borrow-checker IR (BIR), generates Polonius facts from it, and runs the
  Polonius library. That is the same arrangement as here: a frontend's IR, then a separate checker.
  It reached GCC 15 in 2025.
- **mrustc** has no borrow checker; `src/mir/borrow_check.cpp` is a skeleton. Its MIR validation
  and lifetime inference catch moves, uninitialized reads and some returned references, as above.
- **Clang's lifetime safety analysis** (`-fexperimental-lifetime-safety`) is an intra-procedural,
  Polonius-inspired analysis of loans over Clang's CFG for C++ pointers. It is designed for finding
  bugs, with warnings, not as a verifier. This checker refuses what it cannot prove instead.

## Next steps

- Moves: drop obligations for types with drop glue, so a moved value is not dropped and an unmoved
  one is; moves of enums and out of enum variants.
- More standard library entries: subslices, `vec![]`, mutable iterators, containers of `&mut T` and of
  structs, and `impl Display` (`Formatter::write_fmt` and the `Try` impls of `?`).
