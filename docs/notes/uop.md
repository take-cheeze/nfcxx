# nfcuop: a UOp IR (`lib/uop`)

A small version of tinygrad's `UOp`: one IR whose nodes are immutable and hash-consed, optimized by pattern-matching
rewrites. The plan is to grow it, stage by stage, from a scalar core to tensor graphs, lowering to loops, C rendering
through `nfceval`, and bindings for the `nfcpoly` languages, so that a graph can be built from Ruby, Lua, Python,
JavaScript or Go and optimized and run by the C++ side. Stages 1 and 2 exist; the rest is a plan.

| Stage | Content | State |
| --- | --- | --- |
| 1 | `Graph` with interning, `DType`/`Scalar`, type-checked ALU ops, `toposort`, `dump`, the interpreter `evaluate` | done |
| 2 | `Pat`, `PatternMatcher`, `graph_rewrite`, `symbolic()` | done |
| 3 | Tensors: shapes, movement ops (reshape, permute, expand), `REDUCE_AXIS`, broadcasting | not started |
| 4 | Lowering to ranges and loads/stores, rendering C, compiling and running it through `nfceval` | not started |
| 5 | `nfcpoly` bindings (`uop_poly.cpp`) and a cross-language test | not started |
| 6 | Autodiff as a rewrite; ONNX import; a WebNN-style builder as a facade | not started |

## Stage 1

- `Graph` owns every node and interns them: building the same `(op, dtype, sources, value or name)` twice returns the
  same `const UOp*`, so pointer equality is structural equality. This is what lets a pattern name be used twice
  ("both sources are the same node") and makes `graph_rewrite`'s memo table cheap. A node's `id` is its creation
  order; sources always have smaller ids.
- Ops: `Const`, `Var`; `Neg Sqrt Exp2 Log2 Sin` (all but `Neg` float only); `Add Sub Mul Max`, `IDiv Mod` (ints),
  `FDiv` (floats), `CmpLt CmpNe` (result Bool), `And Or Xor` (ints and Bool), `Where`, `Cast`. Dtypes: Bool, Int32,
  Int64, Float32, Float64. `Graph::alu` infers the result dtype and throws `nfcuop::Error` for an ill-typed node.
- `evaluate` is the reference semantics, and also what constant folding uses (`eval_op`): integers wrap to their
  width, `IDiv` and `Mod` truncate toward zero like C (`INT_MIN / -1` wraps, division by zero throws), a Float32 node is
  computed in double and rounded to float after every node (exact for `+ - * / sqrt`, may differ in the last bit for
  `Exp2 Log2 Sin` from a float libm), `Max` returns the non-NaN operand, a float-to-int cast truncates, saturates and maps
  NaN to 0.
- `dump` prints one numbered line per node; it does not depend on addresses or ids, so tests compare it with a golden.

## Stage 2

- `Pat::any`, `cvar` (any constant), `cval` (a constant with this value, any dtype) and `op(Op, {sources})` build a
  pattern; `.named("x")`/a name argument captures the node, `with_dtype` constrains it, `ordered()` stops the
  commutative matching (two sources are otherwise tried in both orders). `Pat::op(Op)` matches the op with any sources.
- `PatternMatcher::add(pat, fn)`: the first rule whose pattern matches and whose function returns a node other than
  the input wins; a function returns `nullptr` to decline. `extend` appends another matcher's rules.
- `graph_rewrite(g, pm, root)` rewrites bottom-up to a fixed point with a memo table: sources first, then the rules on
  the rebuilt node, then the replacement is rewritten itself. It throws `Error` after `max_steps` applications or when
  replacements nest 2000 deep. It recurses along the graph depth (no explicit stack yet).
- `symbolic()`: constant folding (a division by zero is left in the graph), constants moved to the right of commutative
  ops, the identities `x+0 x-0 x*1 x/1 x%1 x|0 x^0 x&0 x-x x^x x&x x|x max(x,x) x<x --x`, `x&true`/`x|true` for Bool,
  `Where` with a constant condition or equal arms, a `Cast` to the same dtype, and `(x+c1)+c2 -> x+(c1+c2)` (also for
  `Mul`). **Integer rewrites are bit-exact.** For floats only the identities that hold for every value are applied:
  `x*0`, `x-x`, `x!=x` and the reassociation are skipped (they are wrong for inf and NaN, or change rounding), and
  `x+0 -> x` changes only the sign of a zero (`-0.0 + 0.0` is `+0.0`, the rule returns `-0.0`).

## Tests

`tests/uop/run.sh` builds `tests/uop/test.cpp` with the three library files per back end (`UOP_HOST=1` builds it with
the host g++ and the address and undefined-behaviour sanitizers). It checks interning, the type errors, the interpreter
(wraparound, division, casts, float32 rounding, NaN), a golden `dump`, pattern matching and captures, about 50
simplifications by pointer identity, custom rules and the step limit, and a differential run: 400 random integer
expressions (with `Where`, casts through float, division by 1 to 3) are evaluated before and after `symbolic()` on 35
variable assignments each; the results must be equal, and the rewrite must be idempotent. Replacing a rule by a wrong
one (checked by hand with `x%1 -> x` and with the float reassociation) makes the run fail.

Not checked here: the nfcxx builds. The test and the library were written against the host g++ in an environment where
the EDG submodule (`3rd/edg`) is not available, so `tests/uop/run.sh` has only run with `UOP_HOST=1`; CI runs it with
nfcxx on both back ends. If cproc rejects something in the library, that is where it will show.
