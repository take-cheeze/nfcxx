# Path B SSA (first step)

`scripts/pathb-ssa.rb` converts the stage 2 IR (`docs/notes/pathb-stage2.md`, goldens in `tests/pathb-ir/`) to SSA
control-flow graphs. It reads the text form, so it needs no EDG build. Regression: `tests/pathb-ssa/run.sh`.

## What it does

1. **Basic blocks.** `block`, `if`, `loop` (body/step), `break`, `continue`, `return`, `unreachable`, `goto` and
   `label` become blocks with `br`, `condbr`, `ret` and `unreachable` terminators. Statements after a jump go to a
   fresh block with no predecessor; unreachable blocks are dropped.
2. **Promotion.** A scalar slot (not aggregate, not `long double`) is promoted when every use is a load or store of its
   own type through the slot address. Any other use (`copy`, `addr`, `offset`, `sret`, `bfload`, `load.v`, a call
   argument) keeps it in memory. A register assigned with `set` is always a variable.
3. **Phi placement** on the iterated dominance frontier (Cytron et al.), dominators by Cooper, Harvey and Kennedy.
   Renaming walks the dominator tree.
4. **Cleanup.** Phis whose arguments are all one value are replaced; phis with no uses are removed; a `let` of a
   pure operation with no uses is removed (the list is in `PURE_OPS`; traps, calls and volatile accesses are never
   removed).
5. **Verification** on every function: each name defined once; each use dominated by its definition; each phi has
   one argument per predecessor. A failure exits 1.

Output: `(ssa-function ...)` with `(bb N ...)` blocks, `(phi NAME TYPE (PRED OP)...)`, and `(ssa-promoted ...)`
listing the slots that were removed. Slots that stay in memory keep their `(slot ...)` declarations.

## Decisions

- **Uninitialized reads** of a promoted slot or variable yield zero (`(const T 0)`, `(null T)` for pointers). The IR
  leaves them unspecified (stage 2, item 7), so zero is one allowed choice. Float zero is printed as `0`; a consumer
  that needs a float literal must spell it.
- **Switch** is not converted yet (fallthrough arms). Functions with a switch are left as they are and reported on
  stderr; 4 of 6604 golden functions.
- **Structured interpretation is partial.** `--run` interprets integer code only; `goto`, calls and pointers report
  `structured=unsupported`.

## Numbers (goldens, 2026-11)

6604 functions in `tests/pathb-ir` and `tests/pathb-ssa/cases`: 6600 converted, 12495 slots promoted, every
converted function verified.

## Not done

- No emitter consumes the SSA yet. The QBE emitter (`scripts/pathb-qbe-emit.rb`) relies on QBE's own promotion, so
  its output does not change. PTX, WebAssembly and WGSL emitters need structured control flow; they need a
  structurizer first.
- Dead phi cycles (a phi used only by itself) are kept.
- Verification checks structure, not meaning. Meaning is checked only by `--run` on the hand-written cases in
  `tests/pathb-ssa/cases/`.
