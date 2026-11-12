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
  The unsigned forms check with unsigned comparisons: a narrow result must not exceed the type's maximum, an add wraps below an
  operand, a subtract borrows, a multiply divides back, and a negate of a nonzero value overflows.
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

## GNU C constructs of the kernel's shape (the cproc-removal work)

- **`__builtin_return_address(0)`, `__builtin_frame_address(0)`** (x86-64): IR rvalues `(retaddr)` and `(frameaddr)`; QBE gives every
  function a frame pointer, and a weak helper the driver appends (`# pathb-asm retaddr`, `frameaddr`; `ASM_HELPERS` in
  `scripts/pathb-ssa-build`) reads the caller's `8(%rbp)` or `%rbp`. A call of the helper is followed by an empty call, so QBE does not
  make `return __builtin_return_address(0);` a tail call (`leave; jmp`, which would run the helper in the caller's frame). The inliner
  leaves a function that holds one of them alone. A level other than 0 is refused (`builtin return_address of a level other than 0`).
  `__builtin_extract_return_addr` and `__builtin_frob_return_addr` are the identity. arm64 has no helper: the unit is refused there.
- **`__attribute__((noinline))`**: the front end writes a `(noinline)` function head when `NFCXX_IR_NOINLINE=1` (`pathb-dump
  --ir-noinline`, which `pathb-cc` passes for the SSA emitter only: the other emitters refuse an unknown head), and
  `scripts/pathb-ir-opt.rb` does not inline such a callee.
- **`__attribute__((cleanup(f)))`** (C and C++): `be/nfcxx_ir.c` keeps the stack of the function's variables with a cleanup and
  writes `(eval (call void &"f" &var))` where their scope ends: at a block's end, at `return` (after the value is computed), and
  at `goto`/`break`/`continue` for the variables above the target label's count (`ir_cu_*`).
- **`section("S")`** on a global: `section "S" "aw"` (`"a"` for a const object) on its QBE data, as gcc does; `used` keeps a static
  object that nothing refers to (`(used)` global flag: a root of both prunes). A thread-local with a section is refused.
- **GNU case ranges** of more than 1024 values: a label (`__case_range_N`) in the switch body and, before the switch, one test
  `(le.u (wsub (iconv unsigned_long x) LO) (HI - LO))` and a `goto` to it per range.
- **A flexible array member** initialised by a string or by elements: the global's size is the struct plus them; no bounds check
  is made on an array of size 0.
