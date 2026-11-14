# Switch lowering in Path B

How the SSA emitter (`scripts/pathb-ssa-qbe.rb`, the default driver route) lowers a `switch`. The design follows GCC's
switch lowering, described in https://xoranth.net/gcc-switch/ (the cluster, bit-test and decision-tree rules, and the
thresholds below). GCC's `gcc/tree-switch-conversion.cc` is the reference for the details.

## Stages

1. **Clusters.** Case values in order. Adjacent values with the same target merge into one range `[lo, hi, target]`
   (`switch_ranges`). Fallthrough blocks that only `br` on are skipped first when the block they reach has no phi
   (`switch_forward`), so labels of one body share a target.
2. **Bit tests** (32-bit operands only; a QBE shift count is a 32-bit value; `switch_items`). A run of ranges within a
   window of 31, reaching at most three targets, is one item when it is worth it, GCC's rule:
   - one target: at least 3 case labels,
   - two targets: at least 5,
   - three targets: at least 6.
   The leaf tests the window, `x - lo <=u span`, then `(mask >> (x - lo)) & 1` for each target in turn; the last failing
   test goes to the default.
3. **Balanced decision tree** (`switch_tree_node`). With four or more items, or any bit-test item, each inner block
   splits at the lower bound of the middle item. Leaves test `x == v`, or `x - lo <=u hi - lo` for a range.
4. **Chain.** Three or fewer items with no bit test keep the linear chain of equality tests (`switch_chain_lines`); it
   is cheaper than a tree of that size.

## Phi predecessors

A phi names one predecessor block per incoming edge. A tree sends several jumps to the default, and to a target that
several leaves reach. Such a target that has a phi is entered through one trampoline block (`.jN`), which jumps on, so
the phi keeps a single predecessor.

## Jump tables

A dense switch (a 32-bit operand, at least five case labels, a span of at most eight entries per label, at most 1024
entries) lowers to QBE's `jtab`: `jtab (x - lo)` with one block per slot. Each slot jumps to one shared block per target,
so a target has one predecessor in the IL and a phi names that block. Holes and out-of-range values go to the default.
QBE checks the count and dispatches through a relocated table (amd64, `.data.rel.ro`); other targets refuse `jtab`.

## Not done

- **Probability-weighted splits.** GCC balances its decision tree by profile probability; ours balances by item count.
- **Non-32-bit jump tables.** A `long` switch keeps the tree; a jump table needs a 32-bit index.

## Tests

- `tests/pathb-qbe/cases/switch_tree.cpp`: dense, sparse, merged runs, unsigned, narrow signed, wide, enum,
  fallthrough with a default that has a phi, a switch in a loop.
- `tests/pathb-qbe/cases/switch_bits.cpp`: bit-test groups, three targets with gaps, a group inside a larger tree,
  fallthrough.

Both compare against the gcc backend.
