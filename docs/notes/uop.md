# nfcuop: a UOp IR (`lib/uop`)

A small version of tinygrad's `UOp`: one IR whose nodes are immutable and hash-consed, optimized by pattern-matching
rewrites. The plan is to grow it, stage by stage, from a scalar core to tensor graphs, lowering to loops, C rendering
through `nfceval`, and bindings for the `nfcpoly` languages, so that a graph can be built from Ruby, Lua, Python,
JavaScript or Go and optimized and run by the C++ side. Stages 1 to 3 exist (stage 3 with a numpy-like user API); the rest is a plan.

| Stage | Content | State |
| --- | --- | --- |
| 1 | `Graph` with interning, `DType`/`Scalar`, type-checked ALU ops, `toposort`, `dump`, the interpreter `evaluate` | done |
| 2 | `Pat`, `PatternMatcher`, `graph_rewrite`, `symbolic()` | done |
| 3 | Tensors: shapes, movement ops (reshape, permute, expand), reductions, `evaluate_array`; the numpy-like `np::Tensor` API with broadcasting | done (no slicing, `Shrink`/`Pad` yet) |
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

## Stage 3: tensors and the numpy-like API

- Every node has a `shape` (the empty shape is a scalar; every dimension is at least 1, so there are no empty tensors).
  `Var` and `Const` take a shape; a shaped `Const` is a tensor with every element equal. ALU ops need sources of
  the same shape: **the IR has no implicit broadcasting**; `expand` is explicit. `Reshape`, `Permute` (`arg` is the
  permutation, result dim `i` is source dim `perm[i]`), `Expand` (same rank, a dimension stays or grows from 1), `ReduceSum` and
  `ReduceMax` (`arg` is the sorted axes, which stay with size 1 like tinygrad's `REDUCE_AXIS`) are checked at
  construction and interned with shape and `arg`. `dump` appends `shape=[..]`, `perm=[..]`, `axes=[..]` for them.
- `evaluate_array(root, {name: Array})` interprets tensor graphs (`Array`: dtype, shape, one `Scalar` per element). A
  reduction starts from the first element of each group and adds (or takes the max) in row-major order of the source.
  It is a reference, not fast.
- `symbolic()` gained: a movement op of a `Const` is a `Const` of the new shape (so `x + 0`, folding and the other rules apply to
  tensors); same-shape `Reshape`/`Expand`, the identity `Permute`, `Reshape(Reshape)`, `Expand(Expand)`, `Permute(Permute)` (composed),
  and a reduction over axes of size 1 are removed; `ReduceMax` of a `Const` and an integer `ReduceSum` of a `Const` fold.
  Folded constants and zero/true results take the node's shape.
- **The numpy-like API** is `lib/uop/nfcuop_np.hpp`: a `Session` (owns the `Graph` and the data of tensors made from arrays) and
  a lazy `Tensor`: `np.array`, `array2d`, `from`, `scalar`, `zeros`, `ones`, `full`, `arange`, `linspace`, `eye`, `placeholder`;
  `reshape` (with `-1`), `transpose`, `T`, `swapaxes`, `flatten`, `squeeze`, `expand_dims`, `broadcast_to`, `astype`; `sum`, `mean`,
  `max`, `min`, `var`, `stddev` (axes, negative axes, `keepdims`); `+ - * / % < > <= >= == != & | ^`, with numpy broadcasting and with scalars on
  either side; `where`, `maximum`, `minimum`, `clip`, `abs`, `sqrt`, `exp`, `log`, `sin`, `cos`, `tanh`, `sigmoid`, `relu`, `square`,
  `reciprocal`, `softmax`, `log_softmax`, `floor_divide`, `matmul`/`dot` (1-D and N-D, batch dimensions broadcast); `numpy()`,
  `tolist()`, `item()`, `str()`, `dump()` realize or show a tensor. `Session::eval(t, feeds)` realizes with placeholders bound; with
  `Session::optimize` (default) the graph goes through `symbolic()` first.
  Everything is built from the ~20 IR ops: `exp` is `exp2(x*log2 e)`, `matmul` is reshape + broadcast `Mul` + `ReduceSum`, `min` is
  `-max(-x)` (the complement for ints), `softmax` is `exp(x-max)/sum`.
- Differences from numpy, on purpose: five dtypes (bool, int32, int64, float32, float64); promotion is the larger in that order, so
  int64 + float32 is float32; `/` and the float functions of ints compute in float32 (numpy uses float64); a float scalar next to a
  float64 tensor stays exact; `%` and `floor_divide` follow numpy's sign rules but only for ints; `==` and `!=` are elementwise
  (they return a `Tensor`); `min`/`max` skip NaN. Not there: indexing and slicing, concatenate/stack/pad (need `Shrink`/`Pad` ops),
  random numbers, `argmax`, `cumsum`, `prod`, `pow`, complex numbers, in-place updates, autodiff.

## Tests

`tests/uop/run.sh` builds `tests/uop/test.cpp` with the three library files per back end (`UOP_HOST=1` builds it with
the host g++ and the address and undefined-behaviour sanitizers). It checks interning, the type errors, the interpreter
(wraparound, division, casts, float32 rounding, NaN), a golden `dump`, pattern matching and captures, about 50
simplifications by pointer identity, custom rules and the step limit, and a differential run: 400 random integer
expressions (with `Where`, casts through float, division by 1 to 3) are evaluated before and after `symbolic()` on 35
variable assignments each; the results must be equal, and the rewrite must be idempotent. Replacing a rule by a wrong
one (checked by hand with `x%1 -> x` and with the float reassociation) makes the run fail.

`tests/uop/test_np.cpp` adds shape inference and errors, `evaluate_array` on every movement op and reduction, tensor rewrite
rules, a second differential run (300 random chains of permute, reshape, reduce, expand, `Where` and integer arithmetic over
a `2x3x2` input, 900 comparisons before and after `symbolic()`), and about 150 checks of the numpy-like API against values worked out by hand
(`matmul`, broadcasting, promotion, numpy's floor semantics, `softmax`, reductions, placeholders, laziness, errors).

Not checked here: the nfcxx builds. The test and the library were written against the host g++ in an environment where
the EDG submodule (`3rd/edg`) is not available, so `tests/uop/run.sh` has only run with `UOP_HOST=1`; CI runs it with
nfcxx on both back ends. If cproc rejects something in the library, that is where it will show.
