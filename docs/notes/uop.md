# nfcuop: a UOp IR, an ONNX-style graph and a numpy-like API (`lib/uop`)

A small version of tinygrad's `UOp`: one IR whose nodes are immutable and hash-consed, optimized by pattern-matching
rewrites. Above it sits a high-level graph in the shape of ONNX, and above that a numpy-like Tensor API:

```
np::Tensor  (numpy-style C++ API, lazy)                 nfcuop_np.hpp
   │ builds
hir::Graph  (ONNX opset 18 operators, symbolic dims)    nfcuop_hir.hpp ──► to_onnx(): a .onnx file, nothing lowered
   │ hir::Lowerer (nfcuop_lower.cpp)
ut::Tensor  (numpy-style builder directly on UOps)      nfcuop_ut.hpp
   │ builds
Graph / UOp (hash-consed nodes, shapes, rewrites)       nfcuop.hpp
   ├── evaluate_array()  the reference interpreter
   └── render_c()        C source (fused loop nests) ── cc -shared, dlopen ──► CModule::run()      nfcuop_cgen.hpp
```

The plan is to grow it stage by stage so that a graph can be built from C++ (and later Ruby, Lua, Python, JavaScript and Go
through `nfcpoly`), exported to ONNX, optimized and run. Stages 1 to 5, autodiff (stage 6, see the table) and the ONNX layer exist; ONNX import exists; symbolic dimensions are step 1 of stage 7 (below), symbolic shapes in UOps are not started.

| Stage | Content | State |
| --- | --- | --- |
| 1 | `Graph` with interning, `DType`/`Scalar`, type-checked ALU ops, `toposort`, `dump`, the interpreter `evaluate` | done |
| 2 | `Pat`, `PatternMatcher`, `graph_rewrite`, `symbolic()` | done |
| 3 | Static shapes: movement ops (`Reshape Permute Expand Shrink Pad Flip`), reductions, `evaluate_array`; the UOp-level builder `ut::Tensor` with broadcasting, slicing, concatenation | done |
| 3b | `hir::Graph`: ONNX-style operators with shape inference, ONNX export, lowering to UOps; `np::Tensor` over it | done |
| 4 | Rendering UOp graphs to C (fused loop nests), compiling with `cc` and running through `dlopen`; selectable as a backend of `eval` | done (plain loops: no tiling, vectorization or threads) |
| 5 | `nfcpoly` bindings (`nfcuop_poly.cpp`) and a cross-language test | done (`uop-poly.md`) |
| 6 | Autodiff on the `hir` graph by onnxsim (`hir::gradients_via_onnxsim`, `np::grad`; [uop-autodiff.md](uop-autodiff.md)); ONNX **import** (`Graph::from_onnx` / `merge_onnx`) | done (onnxsim's rules cover a subset of the operators; the forward operators `Gemm Gather Erf Conv MaxPool AveragePool BatchNormalization InstanceNormalization LayerNormalization` are in `hir` now (`tests/uop/test_nn.cpp`), and their gradients come from onnxsim's rules, not yet checked in `test_grad`) |
| 7 | Dynamic shapes (below) | step 1 done (symbolic dimensions in `hir`, `tests/uop/test_sym.cpp`); step 2 done (symbolic loops in the C renderer, `tests/uop/test_cgen.cpp`) |

## Stage 1: the scalar core

- `Graph` owns every node and interns them: building the same `(op, dtype, sources, value or name, shape, arg)` twice returns
  the same `const UOp*`, so pointer equality is structural equality. This is what lets a pattern name be used twice
  ("both sources are the same node") and makes `graph_rewrite`'s memo table cheap. A node's `id` is its creation
  order; sources always have smaller ids.
- Ops: `Const`, `Var`; `Neg Sqrt Exp2 Log2 Sin` (all but `Neg` float only); `Add Sub Mul Max`, `IDiv Mod` (ints),
  `FDiv` (floats), `CmpLt CmpNe` (result Bool), `And Or Xor` (ints and Bool), `Where`, `Cast`. Dtypes: Bool, Int32,
  Int64, Float32, Float64. `Graph::alu` infers the result dtype and throws `nfcuop::Error` for an ill-typed node.
- `evaluate` is the reference semantics, and also what constant folding uses (`eval_op`): integers wrap to their
  width, `IDiv` and `Mod` truncate toward zero like C (`INT_MIN / -1` wraps, division by zero throws), a Float32 node is
  computed in double and rounded to float after every node (exact for `+ - * / sqrt`, may differ in the last bit for
  `Exp2 Log2 Sin` from a float libm), `Max` returns the non-NaN operand (the second one when they compare equal, so `max(0.0, -0.0)` is `-0.0`), a float-to-int cast truncates, saturates and maps
  NaN to 0.
- `dump` prints one numbered line per node; it does not depend on addresses or ids, so tests compare it with a golden.

## Stage 2: patterns and rewriting

- `Pat::any`, `cvar` (any constant), `cval` (a constant with this value, any dtype) and `op(Op, {sources})` build a
  pattern; a name argument captures the node, `with_dtype` constrains it, `ordered()` stops the
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

## Stage 3: shapes, tensors, slicing

- Every node has a `shape` (the empty shape is a scalar; every dimension is at least 1, so there are **no empty tensors**).
  `Var` and `Const` take a shape; a shaped `Const` is a tensor with every element equal. ALU ops need sources of
  the same shape: **the IR has no implicit broadcasting**; `expand` is explicit. `Reshape`, `Permute` (`arg` is the
  permutation, result dim `i` is source dim `perm[i]`), `Expand` (same rank, a dimension stays or grows from 1), `ReduceSum` and
  `ReduceMax` (`arg` is the sorted axes, which stay with size 1 like tinygrad's `REDUCE_AXIS`), `Shrink` (`arg` is starts then
  ends), `Pad` (before then after, zero or false fill) and `Flip` (axes) are checked at construction and interned with shape
  and `arg`. `dump` appends `shape=[..]` and `perm=`, `axes=`, `starts=`/`ends=`, `before=`/`after=`.
- `evaluate_array(root, {name: Array})` interprets tensor graphs (`Array`: dtype, shape, one `Scalar` per element). A
  reduction starts from the first element of each group and adds (or takes the max) in row-major order of the source.
  It is a reference, not fast.
- `symbolic()` also: a movement op of a `Const` is a `Const` of the new shape (so `x + 0`, folding and the other rules apply to
  tensors); same-shape `Reshape`/`Expand`/`Shrink`/`Pad`, the identity `Permute`, `Reshape(Reshape)`, `Expand(Expand)`,
  `Permute(Permute)` (composed), `Flip(Flip)`, a flip of size-1 axes and a reduction over size-1 axes are removed; `ReduceMax` of a
  `Const` and an integer `ReduceSum` of a `Const` fold. Folded constants and zero/true results take the node's shape.
- `ut::Tensor` (`nfcuop_ut.hpp`) is the numpy-style builder directly on UOps: broadcasting by `reshape`+`expand`, dtype promotion,
  reductions, `matmul` as reshape + broadcast `Mul` + `ReduceSum`, `exp` as `exp2(x*log2 e)`, `min` as `-max(-x)` (the
  complement for ints), `softmax` as `exp(x-max)/sum`. Slicing `a[start:stop:step]`: `slice_indices` (Python's rules) gives
  the elements; the run `low..high` is a `Shrink`, a step above 1 is a `Pad` to a multiple of the step, a `Reshape` to
  `(count, step)` and a `Shrink` to column 0, and a negative step is a `Flip`. `concatenate` pads every part to the full
  length and selects with a padded Bool mask through `Where`, so it is exact (adding zeros would turn `-0.0` into `+0.0`).
  This layer is also what `hir::Lowerer` calls; use it directly if you want UOps and no graph.

## The ONNX-style graph (`nfcuop_hir.hpp`)

- `hir::Graph` holds `Value`s (name, dtype, shape: integers or symbols, see stage 7) and `Node`s that are ONNX operators with ONNX's names, inputs and
  attributes: `Identity Cast Neg Abs Relu Not Sqrt Exp Log Sin Cos Tanh Sigmoid Add Sub Mul Div Mod Max Min And Or Xor BitwiseAnd
  BitwiseOr BitwiseXor Equal Less Greater LessOrEqual GreaterOrEqual Where Clip MatMul Transpose Reshape Squeeze Unsqueeze
  Expand ReduceSum ReduceMean ReduceMax ReduceMin ReduceProd Softmax LogSoftmax Slice Concat Pad Gemm Gather Erf Conv MaxPool
  AveragePool BatchNormalization (inference) InstanceNormalization LayerNormalization Tile CumSum ArgMax ArgMin Pow Floor
  Ceil IsNaN IsInf`, and the forward operators listed in `nfcuop_hir.hpp`. Operands that ONNX wants as constants
  (Reshape's shape, the axes of Squeeze/Unsqueeze/Reduce*, Slice's bounds) are initializers; `add_node` infers dtype and shape
  with ONNX's rules (numpy broadcasting, no implicit dtype conversion, `Div` on ints truncates, `Mod` with `fmod=0` follows the
  divisor's sign) and throws `Error` for anything ONNX would reject.
- `Graph::to_onnx(outputs)` writes a **ModelProto** (IR version 8, opset 18, producer `nfcuop`) with a hand-written protobuf
  writer: only the nodes, initializers (raw little-endian data) and inputs the outputs depend on. No ONNX library is linked.
  `tests/uop/onnx_check.py` loads every exported test model with `onnx.checker.check_model(full_check=True)` and runs it in
  onnxruntime; the results equal the UOp interpreter's.
- `Graph::merge_onnx(bytes)` / `Graph::from_onnx(bytes)` read a ModelProto back (hand-written protobuf reader, `nfcuop_onnx_import.cpp`): the
  writer's output round-trips to the same bytes, models made by the onnx package import, and a model computed from a sub-graph is merged
  into the graph it came from by value names (this is how the gradients of onnxsim come back, [uop-autodiff.md](uop-autodiff.md)).
- `hir::Lowerer` lowers values to `ut::Tensor`s, memoized: inputs become placeholders, initializers buffers (a uniform initializer
  becomes a shaped `Const` so it folds), each operator calls the matching `ut` function. It checks that every lowered tensor has
  the dtype and shape the graph inferred. An ONNX `Cast` float-to-int truncates like the interpreter's cast; for NaN and out-of-range
  values ONNX leaves the result undefined while nfcuop saturates and maps NaN to 0.

## The numpy-like API (`nfcuop_np.hpp`)

`np::Session` owns the `hir::Graph`, a `ut::Session` and the `Lowerer`; `np::Tensor` is a lazy handle to a value of the graph.

```cpp
nfcuop::np::Session np;
auto x = np.placeholder("x", {2, 3});
auto w = np.array({1, 0, 0, 1, 1, 1}, {3, 2});
auto y = softmax(matmul(x, w) + np.array({0.5, -0.5}));
np.save_onnx("model.onnx", {{"y", y}});            // ONNX, nothing lowered
Array r = np.eval(y, {{"x", some_array}});         // lowers to UOps, symbolic(), interpreter
```

Constructors: `array`, `array2d`, `from`, `scalar`, `zeros`, `ones`, `full`, `arange`, `linspace`, `eye`, `placeholder`. Shape: `reshape` (with
`-1`), `transpose`, `T`, `swapaxes`, `flatten`, `squeeze`, `expand_dims`, `broadcast_to`, `astype`, `slice(axis, start, stop, step)` (`None`
omits a bound), `at(index, axis)`, `flip`, `concatenate`, `stack`. Reductions `sum mean max min var stddev` (axes, negative axes, `keepdims`).
Operators `+ - * / % < > <= >= == != & | ^` with numpy broadcasting and scalars on either side, `where maximum minimum clip abs sqrt exp log sin cos
tanh sigmoid relu square reciprocal softmax log_softmax floor_divide matmul/dot logical_not`; `pow(a, b)` (C++ has no `**`; scalars on either side),
`floor ceil isnan isinf` (members), `prod cumsum argmax argmin` (members, axis None flattens), `tile(a, reps)` and `take(a, indices, axis)`.
Realization: `numpy() tolist() item() str()`;
`dump()` shows the ONNX-style graph, `dump_uops()` the UOps it lowers to. Small constants (scalars, shapes, axes) are shared, and a cast of a
small constant is folded into the constant, so `a * 2` is one `Mul` and one scalar initializer in the model.
Mapping to ONNX: `sum` is `ReduceSum` with an axes input, `T` is `Transpose`, `a[::-1]` is `Slice` with step -1 (end `INT64_MIN`),
`floor_divide` is `Div`, `Mod(fmod=1)`, a sign test and a `Sub`, `%` is `Mod(fmod=0)`, `!=` is `Not(Equal)`, `zeros((2,2))` is an `Expand` of a scalar.
`cumsum` is `CumSum` (the axis is an initializer), `prod` is `ReduceProd`, `argmax` is `ArgMax` with keepdims 1 and a cast to the default int,
`tile` is `Tile`, `take` is `Gather`, `pow` is `Pow` with both operands of one dtype.

How the new operators are lowered (`nfcuop_lower.cpp`, `ut`): `Pow` on floats is `exp(y log|x|)` in float64 with the C99 special values set by
`where` (below); on ints it is repeated squaring over the bits of the exponent. `Floor`/`Ceil` truncate through int64 (exact below 2^52) and keep
`-0.0`. `CumSum` is a masked sum: element `i` sums `x[j]` for `j <= i`, an O(n·S) operator. `ReduceProd` multiplies the factors in order.
`ArgMax`/`ArgMin` are the index of the first extreme value (the last with `select_last_index`) from a max/min reduction and an index mask; a NaN
wins as in numpy. `Tile` is one reshape, an `Expand` and a reshape (exact). `Gather` is the one-hot select of the notes above.

## numpy compatibility

How much of the real numpy library is covered, measured: `tests/uop/np_compat.cpp` evaluates 121 expressions with nfcuop (interpreter and C backend, which must
agree bit for bit) and `tests/uop/np_compat.py` the same 166 with numpy 2.5 (same inputs: float32 and int32 arrays). Two runs:

- **32-bit defaults (the default)**: all 166 agree with numpy in shape and values (rtol 1e-5); 144 agree in dtype too; the other 22 differ only in dtype, and the
  script lists them: numpy's int64/float64 defaults (`arange(5)`, `linspace`, `eye`, `zeros`, `full(.., 7)`, int `sum`/`mean`/`cumsum`/`prod`, `bool.sum()`,
  `int / int`, the int `argmax`/`argmin`, the int `argsort`/`searchsorted`/`count_nonzero`) against nfcuop's int32/float32.
- **numpy's defaults** (`np.default_float = Float64; np.default_int = Int64;`): all 166 agree in shape, values **and dtype**.

The script fails if a dtype difference appears that is not on its list, so the claim cannot drift.

**Default dtypes are a per-Session setting**, `np.default_float` (float32) and `np.default_int` (int32). numpy has no global setting (you pass `dtype=` per call, and
the defaults are float64/int64); here every constructor takes an optional dtype that overrides the session default, and the session default says what the
rest does: `array`, `zeros`, `ones`, `linspace`, `eye`, `scalar`, `placeholder` and float `arange`/`full` give `default_float`; `arange(5)`, `arange(0, 6, 2)` and `full(shape, 7)`
give `default_int` (an integer argument gives an integer, like numpy); `/`, `mean`, `var`, `exp`, `softmax`, `clip` and the other float functions of an integer tensor give `default_float`;
`sum` of bool or of integers narrower than `default_int` gives `default_int` (numpy's rule); bool arithmetic runs in `default_int`. A Python-style scalar is weak, as in numpy 2: it takes the
tensor's dtype, except a float next to an integer tensor, which makes `default_float`. float32 stays float32 under 64-bit defaults (`float32_array * 0.1` is float32).
(The UOp-level builder `ut` keeps float32/int32 and takes dtypes explicitly.)

What is the same: broadcasting; negative axes; `keepdims`; Python slicing rules (clamping, negative bounds and steps); `//` and `%` on ints
follow numpy's floor semantics (the sign of the divisor); `matmul` shape rules including 1-D operands and batch broadcasting; `reshape(-1)`;
float32 arithmetic is rounded like numpy's float32.

Where it differs, on purpose:

- **dtypes**: bool, int32, int64, float32, float64 only. Promotion is the larger of the two in that order, so int64 + float32 is float32
  (numpy: float64). The defaults are int32/float32 where numpy has int64/float64, unless the session is configured otherwise (above).
- **no empty tensors**: every dimension is at least 1, so an empty slice, `arange(0)` or `zeros((0,))` is an error.
- `==` and `!=` are elementwise and return a `Tensor` (as in numpy); `min`/`max` ignore NaN (numpy propagates it); `%` and `floor_divide` are for ints only.
- **`pow` on floats is not correctly rounded.** It is `exp(y log|x|)` in float64, so before the rounding to the dtype it is within a few float64
  ulps of the exact value: `pow(3.0, 2.0)` in float64 is `8.999999999999998` where numpy gives `9.0`. Rounded to float32 (the default) the results
  agree with numpy's except where the exact result lies almost exactly halfway between two float32 values. The special values are C99's, as in numpy.
- **`pow` on ints with a negative exponent** gives 0, and 1 or -1 for the bases 1 and -1 (by the parity of the exponent); numpy raises `ValueError`. A
  graph has no way to raise, and the exponent is often not a constant, so this is not checked.
- **`take` out of range at run time** selects nothing (-0.0 for floats, 0 for ints) where numpy raises `IndexError`. Constant indices are checked when the
  graph is built, which is the same error.
- **`argmax`/`argmin` return the default int** (int32; numpy's `intp` is int64), like the other index-like results; the `ArgMax` operator itself is int64, as in ONNX.
- **`cumsum` is quadratic in the axis size** (a masked sum per output element). It is exact, and the masked elements do not change any sum, -0.0 included.
- **`prod` over several axes** multiplies the factors in row-major order of the reduced axes. numpy's order for one axis is the same; for several axes
  its order is the memory order, which can differ, so floats can round differently in the last bit.
- **`tile` refuses a repetition of 0** (numpy gives an empty tensor, which nfcuop does not have).
- **`floor` and `ceil` of a bool** give `default_float` (numpy: float16, which nfcuop does not have); of an int they are the int, as in numpy.

Not there (numpy features a numpy user would reach for next): fancy and boolean-mask indexing, `...` and `None` in an index (use `slice`, `at`,
`expand_dims`), views (every result is a new tensor, nothing aliases), in-place updates, random numbers, `unique`, `nonzero`, `round`, `pad`,
`outer`/`linalg`, complex and unsigned/small-int/float16 dtypes, strings and structured arrays, and anything that needs a data-dependent output shape.
The Array API functions (`sort`, `argsort`, `einsum`, `tensordot`, `roll`, `tril`, `searchsorted`, ...) are in the table of `docs/notes/array-api.md`. Most of these are a new ONNX operator in `hir` plus its lowering in `ut`; data-dependent shapes
(`unique`, boolean masks) are outside a static-shape design. (Done since: `pow`, `floor`, `ceil`, `isnan`, `isinf`, `cumsum`, `prod`, `argmax`,
`argmin`, `tile`, `take`.)
A realistic target is "the subset of numpy that a model needs": array creation, broadcasting arithmetic, reductions, shape ops, slicing, matmul, the
activation functions. Beyond that numpy is a much larger library, and a port would stay a subset.

## C rendering (stage 4, `nfcuop_cgen.hpp`)

`render_c(roots)` turns the graphs of one or more outputs into one C99 program, `CModule::compile` builds it with `cc -O2 -shared` (the command is
`$NFCUOP_CC`, or `cc`; `nfcxx` also works, see below) and `dlopen`s it, and `CModule::run({name: Array})` feeds the inputs (the `Var`s, sorted by
name) and returns the outputs as `Array`s. In the numpy API: `np.backend = ut::Session::Backend::C;` then `np.eval(t)` or `np.eval_all({t1, t2, ...})`
(the second compiles one program for all of them; modules are cached by source text).

- **Fusion**: elementwise ops, casts, `Where` and the movement ops are C expressions in the loop variables, so a chain of them is one loop nest and no
  temporary exists. A movement op rewrites the index (`Permute` swaps loop variables, `Expand` uses 0, `Shrink` adds the start, `Flip` subtracts, `Reshape`
  re-derives the indices with `/` and `%` unless only size-1 dimensions changed, `Pad` is a bounds test around the load). Index temporaries are bound to
  `const int64_t` locals so the text does not grow.
- **Materialization**: a node gets a buffer when it is a reduction, an output, or is used more than once and is more than an index change of something already
  stored. A reduction is a loop nest of its own with its producer fused in its body; it accumulates over the reduced axes in row-major order and starts from the
  first element, exactly like the interpreter. Forty levels of `a = a + a` are forty loop nests, not 2^40 terms (`tests/uop/test_cgen.cpp`).
  `CProgram::kernels` and `temporaries` count the loop nests and buffers: softmax over a `2x3` input is 4 and 3 (max, shifted exp, sum, divide).
- **Same bits as the interpreter**: integer `+ - *` run in unsigned arithmetic, `IDiv`/`Mod` handle `-1`, every Float32 operation is rounded to float,
  `Exp2/Log2/Sin/Sqrt` are called on doubles and rounded, `Max` has the interpreter's NaN and signed-zero rules, float-to-int casts saturate and map NaN to 0, constants are
  written as hexadecimal floats. The compile flags are `-O2 -fPIC -ffp-contract=off -fwrapv`. **One difference**: an integer division or modulo by zero is 0 in C (the
  interpreter throws), because a trap would kill the process.
- **Verification**: `tests/uop/test_cgen.cpp` compares the generated C with the interpreter, element by element, bit for bit (every NaN equal), on 250 random scalar
  graphs, 150 random integer-tensor graphs (raw and after `symbolic()`), 150 random float32 tensor graphs (inputs include `-0.0`, `1e30`, inf and NaN), hand-written
  graphs for every dtype (int64 extremes, float64 casts, bool logic, int32 edges), 18 numpy-API graphs in one program, and the 100 expressions of `np_compat`.
  Each batch is one compiled program. About 32,000 comparisons.
- **Memory (one arena)**: the intermediates (not the outputs, which the caller owns) share one `malloc`. Each is live from the loop nest that writes it to the
  last one that loads it, and `nfcuop_arena.hpp` places it: a port of onnxsim's greedy activation planner (`memory_planning.cpp`, Pass 2), with the same
  liveness test (two buffers share bytes only when their ranges do not overlap, the ends included) and the same best-fit order (largest first, ties in the
  order the kernels write them). Sizes are rounded to 16 bytes. Not ported: onnxsim's in-place aliasing, since a fused loop nest reads its inputs at other
  indices than it writes. `CProgram` reports `arena_bytes`, `naive_bytes` (one buffer each) and `unplanned`. The chain in `test_cgen.cpp` (ten halving steps
  on 32x128 float32, each with a reduction) needs 32,896 bytes of arena against 148,736 with one buffer each: the peak of the live set.
- **Dimension ranging** (`RenderOptions`): the UOp graph has concrete shapes, so a symbol such as the batch size `N` of an `hir` graph is named per input
  dimension (`input_symbols`) and given an upper bound (`symbol_bounds`). Symbols follow the operators by rules that keep one only where the dimension is
  that symbol's size: elementwise ops, reductions (the reduced axis becomes 1), permute, flip, expand of an integer axis, a reshape that keeps the leading
  symbolic axes, a shrink or pad that does not cut them. Any other dimension is unknown. An intermediate's maximum size takes the bound for each symbolic
  dimension, and the arena is sized from these maxima. The renderer checks every intermediate against its slot, so a bound below an input's size is an
  `Error`, and a symbol without a bound leaves its intermediates with a `malloc` of their own. When the loops can be written in the symbols, the program
  takes the sizes at run time and runs at any size up to the bound (stage 7, step 2, below); otherwise the loops have the concrete sizes.
- **Not done**: no tiling, vectorization, threads or GPU; the loops are plain nested `for`s that the C compiler optimizes. No dynamic shapes in the loops. No
  in-place reuse of an input by an output (see Memory). An output that is a reshape of a reduction is copied.
- **nfcxx as the C compiler**: `NFCUOP_CC=./nfcxx` (it passes `-shared -o`, not the gcc flags). `tests/uop/run.sh` runs the `quick` part of `test_cgen` that way on both
  nfcxx back ends; that path (cproc with hexadecimal float literals, `INFINITY`, `static inline`) was not run where this was written, so CI is its first run.

## ONNX Runtime back end (`nfcuop_ort.hpp`)

`nfcuop::ort::run(g, outputs, feeds)` exports the `hir::Graph` with `to_onnx`, runs it with ONNX Runtime and returns the outputs as
`Array`s (the interpreter's type). It is selected in the numpy API as `np.backend = ut::Session::Backend::Ort` (`np.backend = "ort"` in the
scripting bindings), like the C backend. `ut::Session` has no graph, so it refuses this back end; `np::Session::eval_all` sends the graph to
`ort::run` and lowers nothing.

- **No build-time dependency.** The library is opened with `dlopen` at first use: the path is `$NFCUOP_ORT_LIB`, else `libonnxruntime.so.1`,
  `libonnxruntime.so` or `libonnxruntime.dylib`. A load that fails throws `Error` (and nothing is cached, so the next call retries).
  `ort::available()` tells whether it loads; the tests print SKIP without it.
- **The C API declarations** in `nfcuop_ort.cpp` are a vendored subset of ONNX Runtime 1.29.0's `onnxruntime_c_api.h` (MIT licensed, with
  its notice): the `OrtApi` members that are called, at their indices in the table, and reserved slots for the others. The header itself is not vendored.
- **Symbolic batch**: ORT takes the `dim_param` of the exported model, so an unbound graph runs directly; `Graph::bind` gives a static copy
  that runs the same way. Feeds must agree with the graph's dtype and rank, and every use of one symbol must have one size.
- **Not the same bits**: ORT's own graph optimizations and kernels round floats differently from the interpreter, so
  `tests/uop/test_ort.cpp` compares floats to a relative 1e-5 (absolute 1e-6 near zero) and integers and bools exactly.
- **Not done**: no Windows loader (`dlopen`, as the C back end), no ORT execution providers or options, and the sessions are kept until
  the process ends (keyed by the model bytes).

## tinygrad back end (`nfcuop_tinygrad.hpp`)

`nfcuop::tinygrad::run(g, outputs, feeds)` exports the `hir::Graph` with `to_onnx`, runs it with tinygrad (`tinygrad.nn.onnx.OnnxRunner`) and
returns the outputs as `Array`s. tinygrad is Python only, so the work is done by a Python process: `scripts/tinygrad_run.py`. It is selected as
`np.backend = ut::Session::Backend::Tinygrad` (`np.backend = "tinygrad"` in the scripting bindings), and like the ORT back end it is refused by
`ut::Session` and lowers nothing in `np::Session`.

- **The Python process.** The executable is `$NFCUOP_TINYGRAD_PYTHON` (else `python3`), the helper is `$NFCUOP_TINYGRAD_SCRIPT` (else
  `scripts/tinygrad_run.py`, relative to the working directory). It is started with `fork` and `execvp` (no shell, so no name or path is quoted),
  and every call starts one process: nothing is cached, so a failure is not kept and the next call runs it again.
- **The files.** A scratch directory (`$TMPDIR` or `/tmp`) holds `model.onnx` (the `to_onnx` bytes), one raw file per input (row-major, little
  endian, `bool` one byte), `request.txt` (one line per input and output: the file, the dtype, the shape and the tensor name as hex, so no name
  needs quoting) and, written by the helper, one raw file per output and `result.txt` (the file, dtype and shape tinygrad computed; written last,
  so its presence with exit status 0 is the success signal). The directory is removed when the call ends. Raw files were chosen over `.npy`
  because the C++ side needs no format reader: the layout is the dtype's, which is also how the ORT back end passes tensors.
- **Errors.** The helper's stderr is the text of the `Error` (for example a missing tinygrad, a dtype tinygrad returned that the graph does not
  have, or an exception inside tinygrad). An executable that does not start is reported with `exited 127`. `tinygrad::available()` runs the
  helper with `--check`; the tests print SKIP without it.
- **Symbolic dimensions** run unbound: `OnnxRunner` takes each symbol's size from the feed of its input. The output shapes are the ones tinygrad
  computed (read back from `result.txt`), not the graph's, which is what makes a symbolic output shape work without binding.
- **Not done**: no Windows (the process and pipes are POSIX), no caching of the compiled models or of the Python process, and dtypes are the five
  nfcuop has; any dtype tinygrad returns differently is an error, not a conversion. Float results are compared to a relative 1e-5 in
  `tests/uop/test_tinygrad.cpp`, like the ORT test.

## Dynamic shapes (stage 7, after the static stages)

The static design is deliberate: every shape is a known integer, so shape inference, rewriting and the interpreter are simple and exact. Dynamic
shapes are added in two steps, without changing what the static path means:

1. **Symbolic dimensions in `hir`** (done). A `hir::Dim` is an `onnxsim::SymExpr` (`nfcuop_sym_expr.hpp`, copied from onnxsim, Apache-2.0): an
   integer, or a polynomial in symbols, where a symbol is ONNX `dim_param` (e.g. a batch size `N`). So `4*N` and `N+1` are exact dimensions, and two
   dimensions are equal when they are the same polynomial. Inputs take integers and symbols only (`add_symbolic_input`); `add_input` is unchanged.
   Shape inference follows ONNX: a symbolic dimension broadcasts against an equal one or 1, and anything else with a symbol is an `Error`. A
   reshape's `0` copies a dimension, and a `-1` is the exact quotient of the sizes: `[N,2,2] -> [-1,4]` is `[N,4]`, `[N,4] -> [-1]` is `[4*N]`, and
   `[N,4] -> [-1,3]` is an `Error` (4N is not a multiple of 3). Concatenating along a symbol adds the sizes (`2*N`, `N+M`), and padding adds to it
   (`N+1`). Reductions (also over the symbol's axis), matmul and gemm contractions with equal dimensions, the batch axis of Conv and pooling,
   Transpose, Squeeze, Unsqueeze, Expand and the elementwise operators keep symbols. Slicing or gathering along a symbol, a symbol in a channel or
   spatial axis of Conv and pooling, and a normalization over a symbol (its `Scale` is a constant with integer sizes) are refused, since their
   sizes would have to be known. `to_onnx` writes `dim_param` for a symbol. A derived polynomial gets a fresh `dim_param` name
   (`poly0`, `poly1`, ... never a symbol of the graph), and its exact text (`4*N`) goes in the model's `metadata_props` under
   `nfcuop.dim_expr.<name>`. `from_onnx`/`merge_onnx` read the text back, and the value's shape is inferred from the symbols of the
   graph's inputs, so it binds by N. A dimension with neither a value nor a symbol
   is still refused by the reader. The gradients (`gradients_via_onnxsim`) refuse symbolic graphs.
   Evaluation **specializes**: `Graph::bind({N: 2})` gives a static copy of the graph (every operator inferred again with the sizes), and
   `hir::Evaluator` binds, lowers and evaluates it, caching the lowering per binding (keyed on the bindings in name order). Lowering a value
   that has an unbound symbol throws. This keeps UOps static and is enough for batch-size changes; the numpy API has no symbols yet.
2. **Symbolic loops in the C renderer** (done). A compiled program runs at any size of its symbols up to their bounds, not only at the
   sizes it was rendered for. The renderer is the only place that changes; the UOp IR and the interpreter are untouched.
   - **Representation.** UOp shapes stay concrete integers: the graph is built at a *representative* size per symbol (the size of the
     input that names it). The symbolic form is one `SymDim` per dimension of every node, computed by `sym_rule` from the rules of the
     operators: an integer, a symbol, `Wild` (a constant, or a size-1 dimension that a consumer broadcasts, so its size is the
     consumer's), or `Unknown`. A dimension whose size is 1 and that no symbol names is the integer 1.
   - **Contract (not checked).** Concrete shapes lose which dimension is which symbol, so the renderer reads a dimension or an argument
     (a shrink end, a pad amount) equal to a symbol's representative size as that symbol. The graph must therefore be built with each
     symbol written where its size is, and **no other dimension or argument of the graph may equal the representative size**. A reshape
     that moves a symbol to a dimension of the same size would otherwise look unchanged. `tests/uop/test_cgen.cpp` checks the programs
     at other sizes against the interpreter, which catches a violation; its random chains use representative sizes above every
     dimension they can reach. Removing the contract needs the symbol in the UOp shape (below).
   - **Dynamic programs.** `nfcuop_run` takes a third argument, `const int64_t* sizes`, one size per symbol (`CProgram::symbols`, in
     name order). `CModule::run` reads them from the feeds: every use of a symbol must agree, each size is at least 1 and at most its
     bound (`nfcuop::Error` otherwise, before any code runs), and the outputs take their shapes from the sizes. Loop bounds, the strides
     of flat indices, the reduction loops, the `Pad` bounds and the `Flip` offsets, the copies of duplicate outputs and the mallocs of
     unplanned intermediates are C expressions in the sizes; integers stay literals.
   - **Arena.** The planner is unchanged and sized from the bounds, so a dynamic program keeps the saving of PR #219. An intermediate
     without a bound keeps a malloc of its run-time size. A symbol with a bound is checked against it at run time, so the arena is safe.
   - **Fallback.** When codegen needs a dimension that is `Wild` or `Unknown` (a reshape that moves a symbol, a cut of a symbolic
     dimension, an expand of a size-1 dimension whose consumer is not an elementwise op, a materialized constant, an output that is one of
     these), `render_c` renders the graph again with integer loops: `CProgram::dynamic` is false, the program has no size argument and
     runs only at its representative sizes (other sizes throw). Its C is the one of the static renderer, so a graph with no symbol is
     unchanged byte for byte. The fallback also plans its arena as before (wildcards are planned at their concrete size).
   - **Verification.** `tests/uop/test_cgen.cpp` (`dynamic_sizes`, `random_symbolic_sizes`): a batch chain (elementwise ops with a
     constant, a reduction over the non-batch axis, an expand of it) rendered once at batch 3 with bound 8 runs at 1, 2, 3, 5 and 8 rows and
     equals the interpreter bit for bit, and 9 rows throws; without a bound it runs at 1, 5 and 40; the halving chain of 32 x 128 gives the
     static arena (32,896 bytes against 148,736) at every size up to 32; two inputs sharing a symbol agree or throw; a reshape that moves the
     symbol falls back and runs at its own size only; 32 of 60 random chains are dynamic and all agree at their sizes. Static graphs: the
     generated C of ten graphs (plain, reductions, shared intermediates, int64, a materialized expand and constant, and two symbolic
     fallbacks) is identical to the one before this change.
   - **Remains.** (a) Symbol identity in UOp shapes (a `Var` as a dimension, tinygrad's `Variable`): it removes the contract above and
     lets a reshape that moves a symbol, a cut of one, or a broadcast with no symbolic consumer stay dynamic; it touches shape inference,
     `Reshape` and `Expand` validation and the rules of the renderer, and it is the step to take next. (b) A constant or a size-1 broadcast
     that is an output is not dynamic yet (fallback). (c) The bound is a check and the size of the arena, never a loop bound: a
     dynamic loop runs over the run-time size. (d) The ONNX, tinygrad and ONNX Runtime back ends keep their own symbol handling (`Graph::bind`, dim
     params); this change does not touch them.

Data-dependent shapes (`NonZero`, boolean masks) stay unsupported.

## Tests

`tests/uop/run.sh` builds and runs, per back end (`UOP_HOST=1`: with the host g++ and the address and undefined-behaviour sanitizers only):

- `test.cpp`: interning, the type errors, the interpreter (wraparound, division, casts, float32 rounding, NaN), a golden `dump`, pattern
  matching and captures, about 50 simplifications by pointer identity, custom rules and the step limit, and a differential run: 400 random integer
  expressions are evaluated before and after `symbolic()` on 35 variable assignments each; the results must be equal, and rewriting twice changes nothing.
- `test_ut.cpp`: shape inference and errors, `evaluate_array` on every movement op and reduction, the rewrite rules for them, a second differential run (300
  random chains of permute, reshape, reduce, expand, shrink, pad, flip, `Where` and integer arithmetic, 900 comparisons), and the checks of the
  UOp-level builder against values worked out by hand.
- `test_sym.cpp`: symbolic dimensions (stage 7, step 1): an MLP with a batch symbol at two batch sizes against values worked out by hand, the
  `Evaluator` cache, the shape-inference results and refusals, polynomial dimensions (`N*4`, `N+1`, `2*N`) evaluated at two batch sizes, `bind`,
  the exported `dim_param` and its reader; two models for `onnx_check.py`.
- `test_np.cpp`: the same checks through the user-facing API and the graph (values, errors, the default-dtype settings in both configurations, `slice`/`at`/`flip`, `concatenate`/`stack`, constant sharing, the
  ONNX export bytes), and the `hir` error cases. For each new operator (`pow`, `floor`, `ceil`, `isnan`, `isinf`, `cumsum`, `prod`, `argmax`,
  `argmin`, `tile`, `take`) the values are hand-computed or checked against numpy's, and an ONNX round trip (export, read back, export again
  byte-identical, the read-back graph lowered and interpreted equal to the API's values). It writes eleven models (an MLP, broadcasting arithmetic,
  reductions and shape ops, integer division and modulo, math functions, slicing and concatenation, batched matmul, floor/pow with NaN and infinities,
  cumsum and prod, argmax/argmin, tile and take) with the interpreter's results next to them.
- `onnx_check.py`: every model through `onnx.checker` (with `full_check`, which re-infers all shapes) and onnxruntime, outputs compared with the interpreter's.
- `test_ort.cpp`: the ONNX Runtime back end (above), against the interpreter; prints SKIP without the library.
- `test_cgen.cpp`: the C renderer (above), including the programs that run at several sizes (stage 7, step 2).
- `np_compat.cpp`/`np_compat.py`: the 100-expression numpy comparison above, with 32-bit and with 64-bit defaults.

Replacing a rule by a wrong one (checked by hand with `x%1 -> x` and with the float reassociation) makes the runs fail.
The Python checks print SKIP when numpy, onnx or onnxruntime is missing.

Not checked here: the nfcxx builds. The library and tests were written against the host g++ in an environment where the EDG submodule (`3rd/edg`) is not
available, so `tests/uop/run.sh` has only run with `UOP_HOST=1`; CI runs it with nfcxx on both back ends. If cproc rejects something in the library
(it uses `std::map`, `std::function`, `std::deque`, templates with `enable_if_t`), that is where it will show.
