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
- **Opaque.** Anything not in the whitelist is an opaque class of its own: calls, stores, loads (a load of a slot is also
  opaque, but the memory rules below may merge it with an earlier value), checked operations outside `CHECKED_OPS` (bounds
  checks, `cf2i`), `bfload`, `fconv`, float operations, `static`/`barrier` statements. The checked operators `cdiv crem
  cshl cshr` are not opaque: see [Checked operators](#checked-operators-shifts-and-division). An opaque class is never
  merged with another opaque class
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

**Floats.** The interpreter models IEEE binary64 (`double`, a Ruby Float) and binary32 (`float`, rounded to single
precision after each operation; see `round_float` in `pathb-ssa.rb`). The e-graph folds `fadd fsub fmul fdiv` and `fneg`,
`fconv` and `i2f`/`u2f` on constants, with the same rounding, and `lt.f`, `le.f`, `eq` and `ne` on float constants with
IEEE comparisons (NaN is unordered). A float constant is a class of its own, and `0.0` and `-0.0` are different classes
(a Ruby Hash treats them as one key, so `const_key` keeps the sign). Two results are not folded: an infinity or NaN,
which has no constant text, and an `i2f` from an integer beyond 2**53, which the interpreter does not model. `cf2i`
traps on NaN, infinities and out-of-range values, so it stays opaque, and it is never folded.
No float identity is applied: `x + 0` is not `x` for `x = -0.0`, and `x * 0` is not 0 for infinities or NaN.

**Pointers.** Pointer arithmetic (`wadd` on a pointer type) is commutative, and `index`/`offset` are hash-consed,
but no identity or folding is applied to pointer values.

**Not folded:** `wneg` (the interpreter does not model it, so its folding could not be checked), `not` (its
semantics is not in the interpreter). Division, remainder and shifts are checked operators with their own rules
(below).

## Checked operators: shifts and division

`cdiv`, `crem`, `cshl` and `cshr` are the checked operators of `CHECKED_OPS` (`docs/notes/pathb-stage2.md` section 4).
Each `let` of one with integer type `T` (not `bool`) and register or constant operands becomes a node whose literal
operands include the site (the `let`'s register), so two checked lets are never merged by hash-consing: a trap is
never moved to, or shared with, another place. A checked `let` that is neither folded nor available in its block is
emitted as it was written (its operands are rewritten). Its node is never an extraction form for another class.
Dead-code removal keeps it (`pure_rv?` is false for these operators).

| Rule | Result | Bit-exactness |
|---|---|---|
| `cshl T A N` (or `cshr`) with `A`, `N` constants and `0 <= N < w(T)` | `canon(A << N, T)`, or `canon(A >> N, T)` | the IR's shift: `cshl` shifts the two's complement pattern and narrows to `T` (as the QBE emitter does); `cshr` is arithmetic for signed `T` (Ruby's `>>` on a negative integer is the arithmetic shift) and logical for unsigned `T` (a canonical unsigned value is never negative). Equal to the interpreter (`CheckedMachine`). |
| `cshl`/`cshr` with `N` outside `[0, w(T))` | not folded | the operation traps; the `let` stays and is never removed |
| `cshl T A 0`, `cshr T A 0` | `A` | the count is in range for every width, so no trap is possible; a shift by 0 leaves the bit pattern and the canonical value unchanged |
| `cdiv T A B` with `A`, `B` constants, `B != 0`, and `B != -1` when `T` is signed | `canon(q, T)`, `q = |A| / |B|` with the sign negative iff the signs differ | the IR's division truncates toward zero; the divisor is nonzero and no `INT_MIN / -1` overflow is possible, so nothing traps; the same expression as the interpreter's `cdiv` |
| `crem T A B` with the same constants | `canon(A - q*B, T)` with the same `q` | the IR's remainder takes the sign of the dividend, and `A - q*B` is the truncated remainder, the interpreter's formula; `|rem| < |B|` so it is in range |
| `cdiv T A 1` | `A` | no trap (the divisor is neither 0 nor -1), and `A / 1 = A` for every value, including `INT_MIN` (the quotient does not overflow) |

Not added, on purpose:

- `cdiv T A -1` (`-A` for signed `T`): it wraps only for `A = INT_MIN`, where the IR traps; rewriting it to a negation
  would delete that trap. `tests/pathb-egraph/cases/div_neg1.ir` keeps it.
- Any rewrite of a division by a variable divisor, and `crem T A 1 = 0` (not needed by any case here).
- Folds where the trap condition holds: `cdiv` by 0 or `INT_MIN / -1` with constant operands
  (`div_zero_trap.ir`, `div_const_trap.ir`), and shifts with a count outside the width (`shift_trap.ir`). Those keep
  the trap; `shift_trap_var.ir` keeps a variable-count shift that is also unused.
- Shifts with a variable count and a variable operand: no rule. A count that becomes constant during saturation is
  folded by `fold_checked`, since the node's kids are classes.

**The interpreter.** `pathb-ssa.rb`'s `Machine` raises on `cshl` and `cshr`, so the differential check would skip
every shift. `PathbEgraph.run` therefore uses `CheckedMachine`, a subclass in this file that adds them with the IR's
semantics (trap unless `0 <= count < w`). `cdiv` and `crem` are the interpreter's own, which traps on a zero divisor
and on `INT_MIN / -1`. The subclass belongs in `pathb-ssa.rb`; it is kept here only because that file is not
changed by this pass.

**Floats, not done.** The float identities are not added: `x + 0` is not `x` for `x = -0.0`, `x * 1` and `x - x` fail
for NaN and infinities, and `fneg(fneg(x)) = x` would need the IR to define `fneg` as a sign-bit flip that keeps a NaN's
payload. Section 4 of `docs/notes/pathb-stage2.md` says only "IEEE binary", so that is not proved here. `cf2i` stays
opaque. The NaN payload and its sign are not modelled by the interpreter, so a result that depends on them is not
checked.

## Memory

The slots of a block (`$"x"`, the objects that `pathb-ssa.rb` keeps in memory) are tracked in program order within
the block. The state is a map from a location to the value it holds here: its type and its class (or unknown). A
location is a slot at a known byte offset: the slot itself, or a derived address (`(offset P K)`, `(index P I SIZE)` with
a constant index, `(bitcast T P)`) of it. A block with one predecessor starts with the state the predecessor ends with;
a block with several starts empty.

**Escape analysis** (`analyze_addresses`). A slot escapes when its address, or a derived address, is used other than as
the address of a load or store, as the base of a derivation, or as a nonnull check: an argument of a call, a stored
value, a return value, a phi operand. A function that calls `setjmp` makes every slot escape. Only an escaping slot can be
written through a pointer or by a call, so calls and unknown writes forget only the escaping slots: a local whose address
never escapes keeps its remembered values across them. A store through a derived address of a slot forgets the other
locations of that slot (they may overlap), and an index that is not constant forgets the whole slot and records nothing.

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

The cost of a class is the smallest over its nodes of `the node's cost + the costs of the operands` (the node's cost is 1
under the node-count model, see Cost model below); a constant costs 0 (1 under `weighted` when it does not fit an
immediate); a value
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
  traps. A `FILE.lets` next to a case holds the number of lets the optimized form must have, so a fold is checked
  as well as the traps that must stay.
- The checked-operator cases: `shift_const.ir` (folds, and a shift that wraps), `shift_zero.ir` (`x << 0`, `x >> 0`),
  `shift_trap.ir` (a constant out-of-range shift, unused, must still trap), `shift_trap_var.ir` (a variable-count
  shift that traps for counts outside the width, unused), `div_const.ir` (constant division and remainder folded,
  including unsigned, and `x / 1`), `div_neg1.ir` (`x / -1` kept, traps on `INT_MIN`), `div_const_trap.ir`
  (`INT_MIN / -1` on constants kept) and `div_zero_trap.ir` (a remainder by zero kept).
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

- Goldens: 6599 functions converted and optimized, the four switch functions included. Every output verifies. Lets:
  54984 before, 48725 after (pure lets 42583 -> 36444).
- Common subexpressions across blocks: 3524 lets merged (see the section on that rule).
- Memory: 312 loads merged, 268 stores forwarded, 0 dead stores removed (see the section on the memory rules).
- Control flow: branches (`condbr` and `switch`) 4445 -> 3651; 772 `condbr` and no `switch` folded (the goldens'
  switch operands are not constants); 1453 blocks removed; 65 phis replaced; 21 dead phis removed.
- Budget: 22534 blocks saturated, 0 cut by iterations, 0 cut by nodes; 70295 input e-nodes and 6375 added; 27630
  rule rounds in total.
- Interpreter on goldens: 66 functions run (330 random runs each side, all equal); the other 6533 use calls,
  aggregates passed by value, `static`, `weak` or `barrier` statements, or other constructs the interpreter does not model.
  Slots and pointers into them are modelled (see the interpreter's memory in pathb-ssa.rb).
- New case `tests/pathb-egraph/cases/redundant.ir`: 18 lets before, 2 after. It has a repeated `wadd` in one block,
  a commutative duplicate, `x*1`, `x+0`, `x-x`, `x&-1`, `x^0`, `x*0`, `eq` of two equal sums, a `+3 +4` chain and
  an `iconv` identity; the branch on the now-constant comparison folds to its true arm and the false arm is removed.
- New case `tests/pathb-egraph/cases/switch_loop.ir`: 4 lets before, 1 after (see Verification for the expectations).
- `abi_struct.ir` (31 functions): 226 lets before, 216 after.

## Not done

- **Across blocks, code motion.** The pass only reuses a dominating definition; nothing is hoisted or sunk, so an
  operation computed on two sibling paths stays computed twice, and a loop-invariant operation is not moved out.
  No partial redundancy elimination.
- **Memory within a block.** Loads and stores of a slot are merged and forwarded in program order (see Memory above).
  Stores, calls and volatile accesses are never moved or merged.
- **Memory at merge points.** A block with several predecessors starts with nothing known. Keeping the values that every
  predecessor agrees on (the same register) would forward across joins; not done.
- **Constants.** Integer literals, decimal or hexadecimal (`0x` or `0X`, with an optional sign), are constants in the
  e-graph (`const_value`). Only constants and registers replaced by a dominator reach a block.
- **Memory across blocks.** The memory state starts empty in every block, so a value stored in a dominating block is
  not forwarded, and loads through pointers (other than slots) are never merged. Address-taking forms clear the state
  even though a pure address computation writes nothing; a finer rule would need the escape set of the function.
  (the converter removes them only before this pass). Both would be a separate cleanup.
- **Operators.** The bit-field operations have no rules; float operations fold on constants (see Floats); shifts and
  division have only the checked-operator rules above. `index`/`offset` are hash-consed but have no algebra.
- **Float model.** Binary32 and binary64 are modelled; NaN payloads are not (see Floats above).
- **Cost ties.** Extraction is by node count with ties going to the input form, and a bound register costs 0. So a
  reassociation that makes a `let` redundant does not replace a value that is already emitted: in
  `tests/pathb-egraph/cases/div_const.ir` the sum `((-6 + a) + 2147483647)` keeps two lets, not one.
- **Cost model.** Two models, chosen by `--cost` (`PathbEgraph.optimize_fn(cost:)`). `nodes` (the default) is the node
  count above. `weighted` charges a multiply 3, a float multiply 3 and a float divide 8, and a constant that does not fit
  a 12-bit immediate 1 (a constant that fits costs 0). Neither models latency or register pressure. A choice changes only
  where equal forms with different weights are in the graph: the rules in this pass add equal forms for identities and
  folds, but not yet a multiply-to-shift or a multiply-to-add rewrite, so the two models pick the same forms on the
  current goldens and cases. `tests/pathb-egraph/check.rb` runs the weighted model on every case and checks its results
  against the original, and verifies its output on every golden.
- **Consumers.** The opt-in SSA-to-QBE build (`scripts/pathb-ssa-build`) reads this output. The PTX, WebAssembly and WGSL
  emitters do not read it yet: they need structured control flow first (see `pathb-ssa.md`).
