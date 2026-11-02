# Path B e-graph pass over the SSA form

`scripts/pathb-egraph.rb` optimizes the pure value computations of the SSA form that `scripts/pathb-ssa.rb` prints
(`docs/notes/pathb-ssa.md`). An e-graph (equality graph) keeps many equivalent forms of a value in one equivalence
class; rewrite rules add equal forms instead of replacing the input (equality saturation); a cost model then picks one
form per value. Regression: `tests/pathb-egraph/run.sh`.

    ruby scripts/pathb-ssa.rb FILE.ir | ruby scripts/pathb-egraph.rb --stats - > OPT.ssa
    ruby scripts/pathb-egraph.rb --check OPT.ssa          # verify only

Options: `--iters N` (saturation rounds per block, default 8), `--nodes N` (e-nodes added per block, default 2000),
`--stats` (totals on stderr). The reader, printer, `PURE_OPS`, `Phi` and the interpreter (`Machine`) come from
`scripts/pathb-ssa.rb` by `require_relative`; that file is not changed.

## Pipeline

1. Read the SSA text. Blocks are processed in reverse postorder, so a dominator is always processed before the
   blocks it dominates.
2. **Classify** each `let` of the block into the block's e-graph (below).
3. **Saturate** the block's e-graph with the rewrite rules, within the budget.
4. **Extract and emit** each `let` in order: the cheapest form of its class whose operands are available here. The
   `let` keeps its name when its own form is emitted; intermediate values get fresh names `%gN`.
5. **Common subexpressions across blocks** (below): a pure `let` identical to one in a dominating block takes that
   block's register.
6. Apply the replacements globally (a dropped register is replaced by a register or a constant that dominates it),
   fold the control flow (below), remove pure `let`s without uses (the same rule as the converter's cleanup), and verify the result.

## The e-graph

- **Classes and nodes.** A node is an operator, its result type, its literal operands (types, sizes, offsets) and
  the classes of its register or constant operands. Nodes are hash-consed (equal node, same class) and congruence is
  restored by `rebuild` after every round of rules (union-find; merging two classes merges their node lists).
- **Leaves.** A register defined in another block, a phi result, a parameter. Its class is bound to the register.
  If a dominating block replaced the register by a constant or another register, the leaf is that constant or
  register, so identities in this block see it (the redundancy case relies on this: a `wmul x 0` in the entry block
  makes the `+ 0` after the join disappear).
- **Opaque.** Anything not in the whitelist is an opaque class of its own: calls, stores, `load` (every load is
  opaque; no memory state is tracked), checked operations (`cdiv`, `crem`, bounds checks), `cshl`/`cshr`, `bfload`,
  `fconv`, float operations, `static`/`barrier` statements. An opaque class is never merged with another opaque class
  and never with a class of a different value. Its only merges are identities whose result is the opaque value
  itself (`x + 0 = x` with `x` opaque): the merged expression is equal to it, so the class stays one value.
- **Scope.** An e-graph exists for one block; equalities are not carried into other blocks. A class is emitted in a
  block only from registers and constants that are available there: a register of a dominating block, a register
  already emitted in this block, or a constant. Nothing is moved across blocks (no code motion); equal values in
  dominating blocks are shared by the separate pass in "Common subexpressions across blocks".
- **Pure operators** are the whitelist `PURE_OPS` of `pathb-ssa.rb` minus `load`, `const`, `null`: `iconv`,
  `wadd`, `wsub`, `wmul`, `wneg`, the comparisons, `and`, `or`, `xor`, `not`, `index`, `offset`. Operators without a
  rule (`wneg`, `not`, `index`, `offset`) are hash-consed and never folded.

## Common subexpressions across blocks

`cse_dominator` runs after every block has been emitted and before the replacements are applied. It walks the
dominator tree in preorder with a scoped table keyed by `[type, right-hand side]`, where the right-hand side is the
operator with its literals and its operands after the substitution so far:

- On entering a block, each pure `let` whose key is already in the table is removed, and its register is replaced by
  the register that the table holds. Otherwise its key and register are added to the table.
- On leaving a block, the keys that block added are removed, so a sibling subtree never sees them.

A table entry comes from a block that dominates the one it is used in (or an earlier `let` of the same block), so
the replacement is available at every use, including phi arguments (a use at the end of a predecessor is dominated
too). Keys are exact: operator, type and operands are compared as written, with no commutative reordering (the
e-graph inside a block already handles that). Only the whitelist `PURE_OPS` minus `load`, `const` and `null` is
keyed. Loads, checked operations (`cdiv`, `crem`, `cshl`, `cshr`, bounds, `cf2i`), calls, and everything else are
never keys, so they are never merged or moved. A phi is never a replacement. The operands of a key are already
resolved, so chains of merges are followed in one pass.

Test cases (`tests/pathb-egraph/cases/`): `gvn_dominating.ir` (a `wadd` of the entry block reused in the then arm:
4 lets -> 3), `gvn_siblings.ir` (the same `wmul` in both arms: neither dominates, 4 -> 4), and `gvn_checked_div.ir`
(a repeated `cdiv` in a dominated arm: not merged, 3 -> 3). Their `.lets` files hold the hand-derived let counts.
Disabling the scope pop makes the sibling case fail the verifier.

## Rewrite rules

Integer rules only apply to the integer types of `pathb-ssa.rb`'s `INT_TYPES` (not pointers, not `bool` arithmetic
beyond the listed identities).

| Rule | Result | Bit-exactness |
|---|---|---|
| Constant folding of `wadd wsub wmul and or xor` | `canon(a op b, T)` | the interpreter's semantics: canon reduces mod 2^w to the signed or unsigned range of `T` |
| Constant folding of `iconv T x` | `canon(x, T)` | the interpreter's semantics |
| Constant folding of `eq ne` | 0 or 1 | exact on canonical values |
| `lt.s le.s` folded only for signed operand type; `lt.u le.u` only for unsigned operand type and `bool` | 0 or 1 | a compare folds only where the operator's signedness is the operand's, so the canonical values compare as the IR means them |
| Commutativity of `wadd wmul and or xor eq ne` | the operands swapped | addition and multiplication mod 2^w, bit operations and equality are commutative |
| `x+0 = 0+x = x`, `x-0 = x`, `x*1 = x`, `x|0 = x`, `x^0 = x`, `x&all-ones = x`, `x|x = x`, `x&x = x`, `x^x = 0` | the operand | integer identities: the value is an integer mod 2^w, these hold for every value |
| `x-x = 0`, `x*0 = 0`, `x&0 = 0`, `x|all-ones = all-ones` | constant | integer identities (integers have no NaN; `x*0` is 0 for every integer) |
| `iconv T x = x` when `x` has type `T` | `x` | identity conversion |
| `eq x x = 1`, `ne x x = 0` for integer operands | constant | integers equal themselves |
| Reassociation `(x + c1) + c2 = x + (c1+c2)`, `x - c = x + (-c)` | `wadd` with one constant | wrapping addition mod 2^w is associative and commutative, and `-c` is the wrapped negation, so the sums agree bit for bit |

**Floats.** No float rule is applied: float operations (`fadd`, `fmul`, `lt.f`, ...) are not in the whitelist, so
they are opaque. A float identity would have to hold for every value, including the sign of zero and NaN (`x+0` is
not `x` for `x = -0.0`, `x*0` is not 0 for infinities or NaN); none is needed here, so none is applied.

**Pointers.** Pointer arithmetic (`wadd` on a pointer type) is commutative, and `index`/`offset` are hash-consed,
but no identity or folding is applied to pointer values.

**Not folded:** `wneg` (the interpreter does not model it, so its folding could not be checked), `not` (its
semantics is not in the interpreter), division and remainder (they trap; the whitelist excludes them).

## Extraction

The cost of a class is the smallest over its nodes of `1 + the costs of the operands`; a constant costs 0; a value
already in a register available here costs 0; an opaque value that is not bound yet is unavailable (infinite). Ties
go to the node created first, which is the input form (rewritten forms come later), so an unchanged computation
stays unchanged. The costs are computed for each `let` from the bindings at that point, so the choice never names an
unavailable register. Extraction is greedy per class: a DAG-optimal choice is not attempted.

## Budget

- `--iters` bounds the saturation rounds of a block (one round applies every rule to every node, then `rebuild`).
- `--nodes` bounds the e-nodes that rules add to a block (the input nodes are not counted).
- A block whose saturation reaches a fixed point is **saturated**; one stopped by a bound is **cut** (by iterations or
  by nodes). A cut block is still correct: the graph only contains equal forms, and extraction picks among them.
  `tests/pathb-egraph/check.rb` runs every case and every golden under a tight budget as well (`--iters 1 --nodes 4`
  and `--iters 2 --nodes 20`) and checks the results against the unoptimized form.

## Control flow

The terminators are `br`, `condbr`, `switch` (`(switch OP (case V B)... (default B))`, in memory
`["switch", OP, [[V, B]...], D]`), `ret` and `unreachable`. A `switch` is never pure: it is a terminator, not a `let`,
so no rule or dead-code removal touches it. Its operand is a register or a constant and is rewritten through the
e-graph exactly like a `condbr` operand (through `@subst`).

After the substitution, `fold_control` repeats these steps until none changes anything:

1. **Constant branches.** A `condbr` on a constant becomes `br` to the true arm when the value is nonzero, else the
   false arm. A `switch` on a constant becomes `br` to the first case whose value equals it, else the default. The
   constant is canonical for its type (`canon`, as the interpreter's `val`), and the case values are canonical already
   (the converter writes them so), so the comparison is exact. A constant is an integer, `bool` or pointer literal,
   decimal or hexadecimal (`0x1`, the printer's form of many bool and unsigned constants), or `null`.
2. **Unreachable blocks** are removed (reachability from the entry over the new terminators).
3. **Phi arguments** of the edges that no longer exist are dropped. Each phi keeps one argument per predecessor, so
   the phi arity equals the predecessor list (the verifier checks it).
4. **Phis replaced.** A phi whose arguments are all one operand, self-references ignored, is replaced by that operand
   (`@subst`). A phi with one predecessor left is replaced this way, and the replacement can make a branch constant,
   which the next round folds.
5. **Dead phis.** A phi with no use is removed. A phi used only by itself is kept (as in `pathb-ssa.rb`).

The substitution is applied after each round, before the dead-phi count, so a use inside a replaced phi is not taken
for a dead value. The input function is not changed: `block` returns copies of the phis, so the same parsed function
can be optimized again (`check.rb` does so for the tight budget).

Replacing a phi by its one operand is sound: that operand's definition dominates every predecessor that supplies it,
so it dominates the phi's block, and every use of the phi is dominated by it. Removing an edge only adds dominance
relations, so the uses that remain stay dominated.

## Verification

- The output of every function is checked by the verifier of this file (its own copy of the checks of
  `pathb-ssa.rb`): single definitions, each use dominated by its definition (a phi argument by the end of its
  predecessor), one phi argument per predecessor. The check runs on the optimized form in memory; `check.rb goldens`
  also prints it, reads it back and verifies it, and `run.sh` does the same for the command-line output with
  `--check`. A failure exits 1.
- Differential: `tests/pathb-egraph/check.rb cases` runs each `tests/pathb-ssa/cases/*.ir` and
  `tests/pathb-egraph/cases/*.ir` with a `.args` file: the original, the optimized and the tight-budget form must
  return the same values on the `.args` inputs (whose expected values are checked too) and on 50 random inputs.
  Every optimized form must also have no constant `condbr` or `switch` left.
- `check.rb goldens` converts all 84 golden files (`tests/pathb-ir/*.ir`), optimizes each function, verifies the
  output, and runs the functions that the interpreter models (integer code without calls or pointers) on 5 random
  inputs each, original against optimized.
- New case `tests/pathb-egraph/cases/switch_loop.ir` (`switch_loop.args`, expectations derived by hand): a loop whose
  first `switch` is on `i + 0` (the e-graph makes it `i`, so the switch stays and reads the induction variable), with
  a `case` that `continue`s, a fall-off `default`, and a `break` in the cases; then a second `switch` on `i * 0`
  (constant 0, folded to its case 0, and the other arm removed) and an `if` on `eq(i*0, 0)` (constant true, the else
  arm removed). Per iteration `i`, the sum `s` gains 1 + 10000 + 5 + 2 = 10008 for `i = 0`, nothing for `i = 1`
  (`continue`), 100 + 10000 + 5 + 2 = 10107 for `i = 2`, and 1000 + 10000 + 5 + 2 = 11007 for `i >= 3`, with no
  iteration when `n <= 0`. So `n = 1` gives 10008, `n = 3` gives 20115, `n = 5` gives 42129 and `n = 60` gives 647514.

## Numbers (goldens, 2026-11)

- Goldens: 6599 functions converted and optimized, the four switch functions included (their switch terminators
  now parse). Every output verifies. Lets: 54985 before, 52865 after (pure lets 42455 -> 40453). Before the control
  flow fold, the same run gave 54878 -> 53203 on the 6595 functions that then parsed; the four switch functions were
  not counted.
- Control flow on the goldens: branches (`condbr` and `switch`) 4445 -> 3653; 770 `condbr` and no `switch` folded (the
  goldens' switch operands are not constants); 1451 blocks removed; 65 phis replaced; 21 dead phis removed.
- Budget: 22534 blocks saturated, 0 cut by iterations, 0 cut by nodes; 66294 input e-nodes and 6353 added; 27613
  rule rounds in total.
- Interpreter on goldens: 31 functions run (155 random runs each side, all equal); the other 6568 use pointers,
  calls, floats or other constructs the interpreter does not model.
- New case `tests/pathb-egraph/cases/redundant.ir`: 18 lets before, 2 after. It has a repeated `wadd` in one block,
  a commutative duplicate, `x*1`, `x+0`, `x-x`, `x&-1`, `x^0`, `x*0`, `eq` of two equal sums, a `+3 +4` chain and
  an `iconv` identity; the branch on the now-constant comparison folds to its true arm and the false arm is removed.
- New case `tests/pathb-egraph/cases/switch_loop.ir`: 4 lets before, 1 after (see Verification for the expectations).
- `abi_struct.ir` (31 functions): 226 lets before, 216 after.

## Not done

- **Across blocks, code motion.** The pass only reuses a dominating definition; nothing is hoisted or sunk, so an
  operation computed on two sibling paths stays computed twice, and a loop-invariant operation is not moved out.
  No partial redundancy elimination.
- **Known failure (not from this pass).** `switch` is not a terminator of the e-graph reader (`TERMINATORS` in
  `pathb-egraph.rb`), so the golden functions `bitfield2.ir` (`swE3Neg`), `float_neg_switch.ir` (`classify`), `vla.ir`
  (`in_switch`) and `vla_scope.ir` (`sw`) fail with "block without a terminator", and so do the `switch_*` cases of
  `tests/pathb-ssa/cases`; the same failure occurs without this pass. `run.sh` therefore exits 1 until the switch
  handling is fixed.
- **Memory.** Every `load` is opaque: two loads of the same slot with no store between are not merged, and no
  store-to-load forwarding is done. Stores, calls and volatile accesses are never moved or merged.
- **Constants.** Only decimal literals are constants in the e-graph (`const_value`), so a hex literal such as `0x1` is
  opaque there. It is folded only as a `condbr` or `switch` operand (`const_int`). Accepting hex in `const_value` as
  well would be the same value, but it would change the e-graph's classes, so it is left for a separate step.
- **Operators.** Float arithmetic, shifts, division, conversions to float and the bit-field operations have no rules.
  `index`/`offset` are hash-consed but have no algebra.
- **Cost model.** Node count only. No latency, register pressure or size of constants.
- **No consumer.** The QBE, PTX, WebAssembly and WGSL emitters do not read this output yet (the same state as
  `pathb-ssa.rb`'s output).
