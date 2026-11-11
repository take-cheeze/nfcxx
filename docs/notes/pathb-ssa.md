# Path B SSA (first step)

`scripts/pathb-ssa.rb` converts the stage 2 IR (`docs/notes/pathb-stage2.md`, goldens in `tests/pathb-ir/`) to SSA
control-flow graphs. It reads the text form, so it needs no EDG build. Regression: `tests/pathb-ssa/run.sh`.

## What it does

1. **Basic blocks.** `block`, `if`, `loop` (body/step), `switch`, `break`, `continue`, `return`, `unreachable`, `goto`
   and `label` become blocks with `br`, `condbr`, `switch`, `ret` and `unreachable` terminators. Statements after a
   jump go to a fresh block with no predecessor; unreachable blocks are dropped.
   - **Switch.** The dispatch terminator is `(switch OP (case V B)... (default B))`. `OP` is a register or a constant;
     `V` is an integer canonical for the operand's integer type (`canon`), so the comparison is exact for `char`,
     `unsigned_char` and so on. Each `(case ...)` or `(default)` marker starts a block: the block still open before it
     falls through with a `br`. Statements before the first marker go to a block that nothing reaches. The default
     target is the block after the switch when there is no default marker. `break` leaves the innermost loop or switch;
     `continue` leaves the innermost loop. Markers may sit inside nested `block`s, `if` arms and loops (Duff's device);
     the CFG handles any nesting.
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
  leaves them unspecified (stage 2, item 7), so zero is one allowed choice. Float zero is printed as `0`, which the
  e-graph and the interpreter read as a float literal of that type.
- **Structured interpretation is partial.** `--run` interprets integer, float and scalar pointer code (objects at addresses; `offset`, `index`, `addr`, `bounds`, `nonnull`); `goto`, calls, by-value aggregates and `static`/`weak` report
  `structured=unsupported`. A `case` or `default` marker is interpreted only at block level in the switch body (inside
  nested `block`s); a marker inside an `if` or a loop reports `structured=unsupported`, while the SSA form converts it.

## Numbers (goldens, 2026-11)

6610 functions in `tests/pathb-ir` and `tests/pathb-ssa/cases` (6604 before the switch cases were added, plus the six
`switch_*` cases): all converted, 12520 slots promoted, every converted function verified. The four golden functions
with a switch (`_Z8classifyi`, `_ZN31_INTERNAL_13_bitfield2_cpp_main2swE3Neg`,
`_ZN31_INTERNAL_13_vla_scope_cpp_main2swEii`, `_ZN24_INTERNAL_7_vla_cpp_main9in_switchEii`) convert now.

## Not done

- Control flow: `pathb-egraph.rb --dispatch` (`PathbEgraph.dispatch_structurize`) turns any function into one loop: a
  dispatch block switches on a state slot to the block to run, every edge goes through a block that sets the state and
  returns to the dispatch, and every register that crosses blocks, and every phi, is a slot. The result is valid SSA with
  no phis, and it runs the same as the input (the goldens and the cases compare them). A function with an aggregate
  value that crosses blocks is left as it is (its slot needs the struct layout). A relooper, which would give nested if
  and loop structure, is not done.
- Only the opt-in SSA-to-QBE build reads the SSA (`scripts/pathb-ssa-qbe.rb`, via `scripts/pathb-ssa-build`). The flat QBE
  emitter (`scripts/pathb-qbe-emit.rb`) relies on QBE's own promotion, so its output does not change. PTX, WebAssembly and
  WGSL emitters need structured control flow; they need a structurizer first.
- Dead phi cycles (a phi used only by itself) are kept.
- Verification checks structure, not meaning. Meaning is checked only by `--run` on the hand-written cases in
  `tests/pathb-ssa/cases/`.
