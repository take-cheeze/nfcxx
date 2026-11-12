# Computed goto on Path B (label addresses, `goto *p`)

GNU C's `&&label` and `goto *expr` (EDG: a `ck_address` constant of kind `abk_label`, and `stmk_assigned_goto`) used to be
refused: `(unsupported stmt assigned_goto)`. Lua's lvm.c (`LUA_USE_JUMPTABLE`) is the case that needed it.

## Lowering (be/nfcxx_ir.c)

QBE has no label values, so a label address is not a code address:

- `&&label` is a small nonzero integer, the label's id (`ir_label_id`, module-wide, in order of first use), typed as the
  pointer: `(const (ptr void) 3)`. In a static initializer (`static const void *tab[] = {&&a, &&b}`) it is
  `(scalar OFF (ptr void) (const (ptr void) 3))`. An id is stored, copied and compared like any pointer.
- `goto *p` is `(p2i unsigned_long p)` and a `(switch ...)` over the ids of the address-taken labels of the function
  (`a_label.address_taken`), each case a plain `(goto "L")`, the default `(unreachable)`. So every other pass (SSA,
  structurizer, QBE) sees ordinary gotos and switches. A jump to a label that is not address-taken is not possible, as in gcc.
- Not covered: label differences (`&&a - &&b`, `ck_label_difference`) and `&&label + n` stay unsupported; a label address
  that crosses a function (nested functions, statement expressions) is not meaningful.

## A phi with more than 63 predecessors

Every `goto *` of an interpreter is a switch over all its labels, so a label such as Lua's `ret` is reached from 80 blocks and
its phi has 80 arguments. QBE reads at most 63 (`NPred` in parse.c: "too many arguments"). `split_wide_phis`
(scripts/pathb-ssa-qbe.rb) gives such a block's predecessors in groups of 48: each group jumps to a new block that merges
the group's values with a phi and jumps on, and the block's own phi reads one value per group.

## Trailing `T m[1]` members

With `lstring.c` running, the first check that fired was `(bounds I 1)` on `getshrstr(ts)[l] = 0`: Lua's `TString.contents` is
`char contents[1]`, the pre-C99 flexible array member. gcc treats a trailing array of any size as flexible
(`-fstrict-flex-arrays=0`), so the front end no longer bounds-checks a subscript of the last member of a struct when that
member is `T[1]` (`[]` and `[0]` already had no bound).

## Tests

- tests/c/computed_goto.c: a dispatch table, a label address in a local, a pointer compare, a backward `goto *`.
- tests/c/wide_phi.c: a join of 70 predecessors (fails in QBE without the grouping).
- tests/realworld/run_lua.sh and run_lua_make.sh now run gcc and Path B (the QBE-ONLY markers are gone).
