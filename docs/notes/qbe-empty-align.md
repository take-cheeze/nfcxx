# QBE: alignment of empty classes (scripts/qbe-empty-align.patch)

**Symptom.** `std::optional<long>` returned from a function with two return paths (`return std::nullopt;` and
`return 5;`) reports `has_value()` garbage on the QBE backend. The gcc backend is correct. `uop (QBE backend)` on
PR #208 failed in `tests/uop/test_shaping.cpp`: `BroadcastDim` returned a `SymExpr` whose `Concrete()` optionals
were read as engaged, so the wrong branch built a symbol from uninitialized memory.

**Cause.** QBE's `parsefields()` (parse.c) starts a struct's alignment, and reads each nested type's alignment, from
`ty->align`. cproc emits an empty class (`struct X {}`, EDG's form of an empty class, and the `_Empty_byte` alternative of
libstdc++'s `_Storage` union) with no `align` directive, so the field stays at -1. A field with alignment -1 gives the
mask `(1 << -1) - 1 = 0x7fffffff`, so an empty member after data pads the struct by about 2 GiB, and the struct of
`std::optional<long>` (storage union, then the engaged flag) comes out at the wrong size. In `amd64/sysv.c`
`selret()` the second eightbyte is then not returned in RDX, and the caller reads the engaged flag from garbage.

**Fix.** An empty class has alignment 1 (log2 0), the same as gcc's `struct X {}`. Two reads of `ty->align` in
`parsefields()` clamp -1 to 0: the starting alignment of a struct (`scripts/qbe-empty-struct.patch`, from main) and the
alignment of a nested type (`scripts/qbe-empty-align.patch`, this change). The nested read is the one the storage union
of `std::optional` needs: the IL shape `{ { {E} {l} } b }` is still wrong with only the starting-alignment clamp. The sizes of all the other types in the uop suite are unchanged (checked by dumping every
aggregate's size and alignment before and after the patch: only the alignments of size-0 types differ).

**Test.** `tests/cases/qbe_empty_align.cpp` (`// EXPECT: 0`): the old build exits 3, the patched one 0.
`tests/uop/test_shaping` passes on QBE with the patch.

**Note on debugging.** A patched QBE built from the bare pin, without `scripts/qbe-uninit-slot.patch`, crashes in
`std::sort` on a one-element vector: that build emits `mov 0x0,%rdx`, the null load that patch exists to prevent.
Always rebuild through `scripts/setup-qbe.sh`, which applies the patches in order.
