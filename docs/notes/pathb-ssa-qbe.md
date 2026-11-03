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
- Not yet: checked operations (`cdiv`, `crem`, `cshl`, `cshr`, `cf2i`, bounds and nonnull checks, which need trap
  helpers), `switch` (needs compare chains), floats and `double`, globals, calls to module functions, aggregates,
  volatile accesses, and nested expression operands that the converter did not let-bind (seen in `switch_loop.ir`).

A function outside the subset raises `QbeUnsupported` and nothing is emitted for it, so a module with an unsupported
function still emits the rest.

## Status

`tests/pathb-ssa-qbe/run.rb` on the current cases: 11 match the interpreter, 0 mismatches, 23 skipped (checked
operations, switch, floats, memory and setjmp cases that need the harness's `CaseMachine` or a global model, and
the nested-operand case).

The emitter uses the same naming and cls rules as the QBE it is tested against; a mismatch is a bug in the emitter,
the optimizer, or the interpreter, and the runner reports which one by comparing against the interpreter.

## Next

1. Switch as a compare chain, then the checked integer operations via the EDG runtime trap helpers.
2. Globals and calls to module functions (the same install as the interpreter's `install_module`).
3. Floats (`d`/`s` classes, `cf2i` as truncation with a range trap).
4. Decide the wiring into `bin/nfcxx` (behind an option, Path B only).
