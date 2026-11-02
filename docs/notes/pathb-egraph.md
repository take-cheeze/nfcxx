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
5. Apply the replacements globally (a dropped register is replaced by a register or a constant that dominates it),
   remove pure `let`s without uses (the same rule as the converter's cleanup), and verify the result.

## The e-graph

- **Classes and nodes.** A node is an operator, its result type, its literal operands (types, sizes, offsets) and
  the classes of its register or constant operands. Nodes are hash-consed (equal node, same class) and congruence is
  restored by `rebuild` after every round of rules (union-find; merging two classes merges their node lists).
- **Leaves.** A register defined in another block, a phi result, a parameter. Its class is bound to the register.
  If a dominating block replaced the register by a constant or another register, the leaf is that constant or
  register, so identities in this block see it (the redundancy case relies on this: a `wmul x 0` in the entry block
  makes the `+ 0` after the join disappear).
- **Opaque.** Anything not in the whitelist is an opaque class of its own: calls, stores, loads (a load of a slot
  is also opaque, but the memory rules below may merge it with an earlier value), checked operations (`cdiv`,
  `crem`, bounds checks), `cshl`/`cshr`, `bfload`, `fconv`, float operations, `static`/`barrier` statements. An opaque class is never merged with another opaque class
  and never with a class of a different value. Its only merges are identities whose result is the opaque value
  itself (`x + 0 = x` with `x` opaque): the merged expression is equal to it, so the class stays one value.
- **Scope.** An e-graph exists for one block; equalities are not carried into other blocks. A class is emitted in a
  block only from registers and constants that are available there: a register of a dominating block, a register
  already emitted in this block, or a constant. Nothing is moved across blocks (no code motion).
- **Pure operators** are the whitelist `PURE_OPS` of `pathb-ssa.rb` minus `load`, `const`, `null`: `iconv`,
  `wadd`, `wsub`, `wmul`, `wneg`, the comparisons, `and`, `or`, `xor`, `not`, `index`, `offset`. Operators without a
  rule (`wneg`, `not`, `index`, `offset`) are hash-consed and never folded.

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

## Memory

The slots of a block (`$"x"`, the objects that `pathb-ssa.rb` keeps in memory) are tracked in program order within
the block. The state is a map from a slot to the value it holds here: its type and its class (or unknown). It starts
empty at every block, so nothing is carried into another block.

- **Loads.** `(load T $"x")` with a remembered value of type `T` is the same value: the load shares the class and
  no `let` is emitted for it (its uses get the register of the first load or of the stored value). Otherwise the
  load is an opaque value and the slot now holds it. Loads of different slots are different objects, so they never
  merge with each other.
- **Store-to-load forwarding.** `(store T $"x" V)` records `V` (a register or a constant of type `T`). A later
  `(load T $"x")` with no write in between yields `V`. The type must match: the store's type and the value's type are
  both `T`. A store of an expression, or of another type, leaves the slot's value unknown.
- **Barriers.** A write that may touch any slot forgets the whole state: a store through a pointer or to a non-slot
  address, `copy`, `eval`, `bfstore`, `store.v`, `bfstore.v`, `barrier`, `fence`, `vastart`, `static`, any call,
  `load.v`, `bfload.v`, `vaarg`, `alloca`, and any statement not in the list of memory-neutral forms. An
  address-taking form also forgets it: any `$"x"` that is not the address of a plain load or store (`addr`,
  `offset`, `bitcast`, `sret`, a call argument, the source or destination of `copy`). Plain loads and stores of
  other slots keep the state, as do the pure operators and `bfload`.
- **Volatile.** `load.v` and `store.v` are never merged, forwarded, removed or moved. They are barriers, so no
  value is remembered across them.
- **Dead stores.** A plain store to a slot is removed when no instruction of the function reads the slot or takes its
  address, a later store to the same slot follows in the block with no read or write of memory between them, and
  the stored value is a register or a constant (so the store cannot trap). The rule is implemented but fires on
  no golden: no slot left in memory is written and never read or addressed (the converter promotes the scalar
  ones that are only stored and loaded).
- **Not moved.** No load or store changes its position; an opaque value is emitted where its `let` was.

Cases: `tests/pathb-egraph/cases/memory_*.ir`, with expected values in `.args` and hand-derived instruction counts in
`.counts` (`HEAD N` lines counted in the optimized `main`): duplicate loads, store-to-load forwarding (same type, and
a different type that must not forward), a store across a call, volatile accesses, two slots that are kept, and a
dead store. The interpreter runs these cases with a test-only extension (`CaseMachine` in `check.rb`) for the call,
the slot's address and the volatile forms, which `pathb-ssa.rb`'s interpreter does not model.

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

## Verification

- The output of every function is checked by the verifier of this file (its own copy of the checks of
  `pathb-ssa.rb`): single definitions, each use dominated by its definition (a phi argument by the end of its
  predecessor), one phi argument per predecessor. The check runs on the optimized form in memory; `check.rb goldens`
  also prints it, reads it back and verifies it, and `run.sh` does the same for the command-line output with
  `--check`. A failure exits 1.
- Differential: `tests/pathb-egraph/check.rb cases` runs each `tests/pathb-ssa/cases/*.ir` and
  `tests/pathb-egraph/cases/*.ir` with a `.args` file: the original, the optimized and the tight-budget form must
  return the same values on the `.args` inputs (whose expected values are checked too) and on 50 random inputs.
- `check.rb goldens` converts all 84 golden files (`tests/pathb-ir/*.ir`), optimizes each function, verifies the
  output, and runs the functions that the interpreter models (integer code without calls or pointers) on 5 random
  inputs each, original against optimized.

## Numbers (goldens, 2026-11)

- Goldens: 6599 functions converted and optimized. Every output verifies. Lets: 54878 before, 52602 after (pure lets
  42369 -> 40093). Before the memory rules the e-graph gave 53203. The memory rules merge 312 loads and forward 268
  stores (580 lets); 21 more pure lets become equal once their operands are merged. Dead stores removed: 0.
- Budget: 22516 blocks saturated, 0 cut by iterations, 0 cut by nodes; 69777 input e-nodes (66178 before the memory
  rules: the stored values are now classes) and 6347 added; 27591 rule rounds in total.
- Interpreter on goldens: 30 functions run (150 random runs each side, all equal); the other 6565 use pointers,
  calls, floats or other constructs the interpreter does not model.
- New case `tests/pathb-egraph/cases/redundant.ir`: 18 lets before, 3 after. It has a repeated `wadd` in one block,
  a commutative duplicate, `x*1`, `x+0`, `x-x`, `x&-1`, `x^0`, `x*0`, `eq` of two equal sums, a `+3 +4` chain and
  an `iconv` identity; the branch on the now-constant comparison is kept (see below).
- `abi_struct.ir` (31 functions): 226 lets before, 216 after.

## Not done

- **Across blocks.** No common-subexpression elimination between a dominating block and a dominated one, and no code
  motion. Only constants and registers replaced by a dominator reach a block.
- **Memory across blocks.** The memory state starts empty in every block, so a value stored in a dominating block is
  not forwarded, and loads through pointers (other than slots) are never merged. Address-taking forms clear the state
  even though a pure address computation writes nothing; a finer rule would need the escape set of the function.
- **Control flow.** A `condbr` on a constant keeps its dead arm; phis whose arguments became equal are not removed
  (the converter removes them only before this pass). Both would be a separate cleanup.
- **Operators.** Float arithmetic, shifts, division, conversions to float and the bit-field operations have no rules.
  `index`/`offset` are hash-consed but have no algebra.
- **Cost model.** Node count only. No latency, register pressure or size of constants.
- **No consumer.** The QBE, PTX, WebAssembly and WGSL emitters do not read this output yet (the same state as
  `pathb-ssa.rb`'s output).
