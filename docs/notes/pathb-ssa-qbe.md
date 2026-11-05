# Path B SSA to QBE

`scripts/pathb-ssa-qbe.rb` emits QBE IL from the SSA text of a module (`docs/notes/pathb-ssa.md`), optionally after the
e-graph pass (`docs/notes/pathb-egraph.md`). It is the first consumer of the optimized SSA: until now the optimized form
was only interpreted. QBE (`build/qbe/qbe`) then assembles the IL to native code.

    ruby scripts/pathb-ssa.rb FILE.ir | ruby scripts/pathb-ssa-qbe.rb - > FILE.qbe
    build/qbe/qbe FILE.qbe > FILE.s

End-to-end check: `ruby tests/pathb-ssa-qbe/run.rb [CASE.ir ...]`. For each case with a `.args` file it optimizes
`main`, emits QBE, assembles it under the name `case_main`, links it with a C driver, runs it on each input and compares
with the interpreter. Cases the emitter or the interpreter does not cover are reported as SKIP with the reason.

## Subset

- Types: integer scalars of 8 to 64 bits, `bool`, and pointers. QBE class `w` for types up to 32 bits, `l` for 64-bit
  integers and pointers.
- Operations: `wadd`, `wsub`, `wmul`, `wneg`, `and`, `or`, `xor`; comparisons `eq ne lt.s lt.u le.s le.u`; integer
  conversions (`iconv`); `load` and `store` of scalar objects; `phi`, `br`, `condbr`, `ret`, `unreachable` (as `hlt`).
- Objects: a slot that the converter did not promote is allocated on the stack at entry (`alloc4`/`alloc8`). Address
  operands are `$slot`; a parameter `%k` is `%pk`; a register `%N` is `%vN`.
- `switch`: a chain of `jnz` tests (QBE has no switch). The first test is in the switch block; each later test has its
  own block. A phi of a target names the test block that jumps to it.
- Nested expressions (in operands, switch operands and phi operands) are computed into temporaries first, in the block
  that uses them (a phi operand in its predecessor).
- Checked operations (`cdiv`, `crem`, `cshl`, `cshr`, `cf2i`): each check is a call `pathb_check(cond, code)` placed before
  the operation; codes 1 division by zero, 2 signed overflow, 3 shift count out of range, 4 float to integer out of range.
  The checked add, subtract, multiply and negate (`cadd`, `csub`, `cmul`, `cneg`) check with code 2: a narrow type is
  computed in 64 bits and range-checked; an 8-byte add or subtract uses the sign-bit identities; an 8-byte multiply divides
  the product back by the operand (a divisor of 0 or -1 is replaced by 1, see `checked_arith_lines`), so it needs no runtime.
  Unsigned checked forms are refused, as the flat emitter refuses them.
  The runtime must not return when `cond` is nonzero (it traps; the test driver longjmps out). No block is split. `bool`
  checked ops are not emitted.
- Floats: `s` and `d` classes; float literals are rounded to their type and written as exact hex, so `-0.0` survives.
  Int to float follows the source signedness.
- Globals become QBE `data` with their initialisers (zero, integer and pointer scalars, addresses of module globals).
  Extern, thread-local and other initialisers are not emitted; a reference to one raises `QbeUnsupported`.
- Calls: `(call RET &"name" ARG...)` is a direct call by name; module functions and libc (`_setjmp`, `longjmp`) alike.
- `(nonnull P)` traps on a null pointer (code 5); `(bounds I N)` traps on an index outside [0, N) (code 6), with an
  unsigned comparison so a negative index is caught too.
- Addresses: `(addr $slot)`, `(offset P K)` and `(index P I SIZE)`; a slot of an array type is allocated at its full size.
- Volatile accesses (`load.v`/`store.v`) call the volatile helpers the module declares, as the flat emitter does.
- Aggregates passed or returned by value are lowered when their `abi-type` has a shape the emitter knows; an unknown shape is
  refused.

A function outside the subset raises `QbeUnsupported` and nothing is emitted for it, so a module with an unsupported
function still emits the rest.

## Status

`tests/pathb-ssa-qbe/run.rb` on the current cases: 32 match the interpreter, 0 mismatches, 3 skipped (a double-typed
global in `float_fold`, a volatile access in `memory_volatile`, and an aggregate in `memory_dead_store`), plus
`memory_store_forward`, which the interpreter itself does not model (its typed cells reject an `int` access to a `long`).

The runner runs the interpreter through `tests/pathb-egraph/check.rb`'s `CaseMachine`, so `observe`, `clobber` and the
volatile accesses are modelled on both sides. A case whose `clobber` targets a non-int slot is skipped.
The emitter uses the same naming and cls rules as the QBE it is tested against; a mismatch is a bug in the emitter,
the optimizer, or the interpreter, and the runner reports which one by comparing against the interpreter.

## Next

1. Aggregates by value (copy) and volatile accesses.
2. Decide the wiring into `bin/nfcxx` (behind an option, Path B only).
