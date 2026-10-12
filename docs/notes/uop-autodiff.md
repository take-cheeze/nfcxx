# nfcuop autodiff: reverse mode on the ONNX-style graph (`lib/uop/nfcuop_grad.*`)

`hir::gradients(g, loss, wrt)` appends the backward pass of a scalar float `loss` to the `hir::Graph` ([uop.md](uop.md)) and returns
one value per `wrt`, with that value's shape and dtype. The backward pass is made of ONNX operators only, so a gradient is an
ordinary value of the graph: it is lowered and evaluated by both back ends (interpreter, C), exported with `to_onnx` next to the
loss, accepted by `onnx.checker` and computed by onnxruntime, and can be differentiated again. The numpy-like API has
`np::grad(loss, {w1, w2})` (and `np::grad(loss, w)`) over it.

```cpp
Session np;  np.default_float = DType::Float64;
Tensor x = np.placeholder("x", {4, 3}), w = np.placeholder("w", {3, 2});
Tensor loss = -(onehot * matmul(x, w).log_softmax(1)).sum() / 4.0;
Tensor dw = grad(loss, w);                         // shape (3, 2)
Ts g = grad(loss, {w, x});                         // several at once: one backward pass
np.save_onnx("m.onnx", {{"loss", loss}, {"dw", dw}});
```

## Why at the `hir` level

The UOp graph has no `Exp`, `Tanh`, `Softmax` or `MatMul`: they are already expanded into `Exp2`, reductions and broadcasts, and a
gradient built there would not be an ONNX graph. The ONNX operators are the units a user (and onnxruntime) recognizes, and the
vector-Jacobian product of each is short. The cost is that every ONNX operator needs a rule, and that the backward pass needs
two operators the forward pass did not (`Pad` for `Slice`; `Slice` for `Concat`, already there).

## Algorithm

1. Check: `loss` is a float value with the empty shape; each `wrt` is a float value (an input, an initializer, or the output of
   any node).
2. Forward sweep over the nodes: a value *depends* on a `wrt` if it is one or any input of its producer does. Bool outputs are
   never dependent (a mask is a constant; this also keeps the Bool `Equal` nodes of the rules below out of second derivatives).
3. Backward sweep over the nodes in reverse (they are in topological order, so every use of a value is seen before its
   producer): a node whose output has a gradient `gy` and depends on a `wrt` adds the contributions of its rule to its inputs.
   A value used several times accumulates with `Add`. Contributions to an operand that was broadcast are summed back to its shape
   (`ReduceSum` over the leading and the size-1 dimensions, then `Reshape`).
4. A `wrt` with no gradient gets a zero constant of its shape (`Expand` of a scalar `0`). A `wrt` that is the loss gets a scalar
   `1`. A `wrt` upstream of another `wrt` gets the total derivative (the gradient of an intermediate value is the sum over its
   uses, and the sweep goes on through it).

Constants (scalars, shapes, axes) made by a call are shared by content, so the backward pass does not add one initializer per use.
Rules skip the work for operands that do not depend on a `wrt` (the weights of `Mul` by a data constant cost nothing).

## Rules

`y` is the node's output, `g` its gradient, `x`, `a`, `b` its inputs. "unbc" is the sum back to the operand's shape.

| Operator | Gradient |
| --- | --- |
| `Identity` | `g` |
| `Cast` float to float | `Cast(g)` back to the input dtype |
| `Cast` from bool | none (a mask) |
| `Cast` from int | **error** if the input depends on a `wrt` (see below) |
| `Neg` | `-g` |
| `Abs` | `Where(x > 0, g, Where(x < 0, -g, 0))` |
| `Relu` | `Where(x > 0, g, 0)` |
| `Sqrt` | `g / (2 y)` |
| `Exp` | `g * y` |
| `Log` | `g / x` |
| `Sin`, `Cos` | `g * cos x`, `-g * sin x` |
| `Tanh` | `g * (1 - y^2)` |
| `Sigmoid` | `g * y * (1 - y)` |
| `Add`, `Sub` | `unbc(g)`, `unbc(+-g)` |
| `Mul` | `unbc(g * b)`, `unbc(g * a)` |
| `Div` | `unbc(g / b)`, `unbc(-(g * y) / b)` |
| `Max`, `Min` | `unbc(g * w)` and `unbc(g * (1 - w))`, `w` = 1 where `a` wins, 1/2 at a tie, 0 where `b` wins |
| `Where` | `unbc(Where(c, g, 0))`, `unbc(Where(c, 0, g))`; the condition gets nothing |
| `Clip` | `x`: `Where(lo <= x <= hi, g, 0)`; `lo`: sum of `g` where `x < lo`; `hi`: sum of `g` where `x > hi` (missing bounds are skipped) |
| `MatMul` | 1-D operands are viewed as `(1,K)` and `(K,1)`; `dA = unbc(G B^T)`, `dB = unbc(A^T G)` with the batch dimensions of the other operand summed out; then reshaped to the operand. All rank combinations, batch dimensions broadcast |
| `Transpose` | `Transpose` with the inverse permutation |
| `Reshape`, `Squeeze`, `Unsqueeze` | `Reshape` to the input shape |
| `Expand` | `unbc(g)` |
| `ReduceSum` | `g` reshaped to the keepdims shape, `Expand`ed to the input |
| `ReduceMean` | the same, divided by the number of elements reduced |
| `ReduceMax`, `ReduceMin` | `g` (keepdims shape) times `mask / count`, `mask` = `Equal(x, y)` as float, `count` its `ReduceSum` over the axes |
| `Softmax` | `y * (g - sum(g * y, axis))` |
| `LogSoftmax` | `g - exp(y) * sum(g, axis)` |
| `Slice` | per sliced axis: for step 1 a `Pad`; for a negative step the gradient is first reversed (`Slice` with step -1); for a step `s > 1` a zero block of `s - 1` elements is put after every element (`Reshape` to `(.., n, 1, ..)`, `Concat` with zeros, `Reshape` to `(.., n*s, ..)`, `Slice` off the trailing zeros), then `Pad`. Several axes in one node are done one after the other |
| `Concat` | `Slice` of `g` for each input |
| `Pad` (constant mode) | `Slice` of `g` to the data; the constant value gets `sum(g) - sum(g inside)` |

Not differentiated, and therefore constants of the backward pass: `Not And Or Xor BitwiseAnd BitwiseOr BitwiseXor Equal Less Greater
LessOrEqual GreaterOrEqual` (bool results), `Mod`, and integer `Add Sub Mul Div Max Min Neg Abs Relu Reduce*`, `MatMul`,
`Cast` to an integer or bool type: their outputs never carry a gradient, which is their derivative where it exists (zero).

## Conventions at ties and boundaries

Chosen so that the gradient is a subgradient, symmetric where the function is, and the same on every back end.

| Function at the kink | Gradient |
| --- | --- |
| `Relu(x)` at `x = 0` | 0 |
| `Abs(x)` at `x = 0` | 0 (the sign function) |
| `Max(a, b)`, `Min(a, b)` with `a == b` | 1/2 to each operand (so `max(x, x)` has derivative 1 for `x`) |
| `ReduceMax`, `ReduceMin` with several elements equal to the extreme | the gradient is shared evenly among them (the same convention as `Max`; not "the first index") |
| `Clip(x, lo, hi)` with `x == lo` or `x == hi` | passes to `x` (closed interval); `lo` and `hi` get the gradient of the elements strictly outside |
| `Where(c, a, b)` | decided by `c`; `c` is never differentiated |
| `Sqrt` at 0, `Log` at 0, `Div` by 0 | infinite or NaN, as the formulas give (no guard) |

Equality for the ties is exact floating point equality of the forward values, so a "tie" is only detected when the two values are
bit-equal.

## Bool and integer values

* A comparison, logic or cast-to-bool result is a constant: `x * (x > 0).astype(float)` differentiates (the mask contributes
  nothing, the gradient is the mask), and so does `where(x > 0, ...)`.
* A float value that is cast to an integer type and back (`x.astype(int32).astype(float)`) *depends* on `x` through an integer
  value. The derivative is zero almost everywhere, but a gradient that has to flow into such an integer value is more likely a
  mistake than a request, so `gradients` throws `nfcuop::Error` naming the value. The same holds for an integer `wrt` or an
  integer/bool `loss`. An integer branch that does not depend on a `wrt` (indices, counts of data, labels) is irrelevant and
  allowed.
* There is no `stop_gradient` operator (ONNX has none); a mask is made with a comparison, a constant with `np.array`.

## Second derivatives

Every rule is built from differentiable operators plus bool masks, so `grad(grad(loss, x).sum(), x)` works, for every operator
with a rule; piecewise-linear functions (`relu`, `abs`, `max`, `clip`, `ReduceMax`) have a second derivative of 0, which is the
right value almost everywhere. Their `Where`/`Equal` pieces are the constants of the paragraph above. Tested: `x^3`, `exp`,
`tanh`, `relu`, `max`, a strided slice, and by finite differences of the first derivative for softmax-log, tanh-matmul,
slice-concat and max-clip. A third derivative is the same construction (not tested); the graph grows with each.

## What is not supported

* Differentiating integer or bool values (see above), and `Mod`.
* A `loss` that is not a rank-0 float value (a tensor of shape `(1)` or `(1,1)` is not accepted: reduce it).
* Cropping `Pad` (negative pads), modes other than `constant`, and a `Pad` constant that is not an initializer; the `axes` input
  of opset-18 `Pad`.
* The gradient graph is not optimized: the rules emit their small `Where`/`Equal`/`Cast` pieces per node, constants are shared by
  content but equal nodes are not merged in the `hir` graph (the UOp lowering interns identical nodes, so evaluation does not
  repeat them, but the exported ONNX file does). A gradient of a model with 10 operators adds 16 to 23 nodes.
* Constants made by `np.array` with equal content (up to 64 elements) are one value in the graph (`Session::constant` shares
  them), so two equal arrays are one `wrt` and one gradient. Use a placeholder, or different data, for parameters.

## `Pad` (new in `hir`)

ONNX opset 18 `Pad`: inputs `data`, `pads` (initializer, `[x1_begin, x2_begin, ..., x1_end, x2_end, ...]`, non-negative) and an
optional scalar `constant_value` (an initializer of the data's dtype); attribute `mode` is `constant` or omitted. Shape
inference is in `nfcuop_hir.cpp`, the exporter writes it like any other node, the lowering calls the new `ut::Tensor::pad`
(`pad(before, after)` is the UOp `Pad`; with a nonzero value it picks the value outside with a padded Bool mask, as
`concatenate` does, so `-0.0` data stays exact). Checked in `tests/uop/test_grad.cpp` (values, errors, the gradient of the data and
of the constant) and in onnxruntime through the gradient models.

## Tests (`tests/uop/test_grad.cpp`, part of `tests/uop/run.sh`)

* 100 finite-difference cases in float64 (central difference, step `1e-6`; failing above a relative error of `1e-6`), 1298
  derivative elements: every operator of the table, broadcasting in every binary operator, `MatMul` in twelve rank/batch
  combinations, reductions with axes and keepdims, strided and reversed slices, `Concat`/`stack`, shared sub-expressions,
  layer norm, batched attention, two MLPs (tanh, relu) with softmax cross entropy written with `log_softmax` and a one-hot
  constant, and second derivatives. The loss is a weighted sum with unequal weights. Largest relative error 2.7e-9.
* Exact hand-derived gradients: polynomials, `matmul`, `softmax - onehot`, the softmax Jacobian row, slices, concatenation, every
  tie convention above, masks, unreached and repeated `wrt`, an intermediate `wrt`.
* The hir level: `Identity`, `Cast`, `Clip` bounds, `Pad`, a two-axis `Slice` with steps `2` and `-2`.
* Errors: non-scalar loss, int and bool loss, int `wrt`, a cast through an integer type, a `wrt` of another session, bad ids.
* The gradients of an MLP and of a larger expression, in float64 and float32, evaluated by the interpreter and by the C
  backend: 16 arrays equal bit for bit.
* Four models whose outputs are a loss and its gradients (`grad_mlp`, `grad_ops` with strided slices, `Pad`, `Concat`,
  `Where`, `Clip`, `Max`, `grad_matmul` with batched and 1-D matmul, `grad_second` in float64 with a second derivative) are
  written for `tests/uop/onnx_check.py`: `onnx.checker` (full check) accepts them and onnxruntime 1.29 agrees with the
  interpreter within `rtol 1e-5`.

## Measured

On this machine, float64, `-O1`, interpreter vs the C backend (compile time excluded, cached):

| Model | forward nodes | gradient adds | interpreter fwd / fwd+grad | C fwd+grad |
| --- | --- | --- | --- | --- |
| MLP 32-64-10, batch 64, relu, softmax cross entropy, wrt 4 parameters | 10 | 21 | 15 ms / 82 ms | 1.0 ms |
| batched attention (4, 16, 8) | 6 | 16 | 1.1 ms / 4.6 ms | 0.6 ms |
| strided slices of a 64x64 matrix | 8 | 21 | 0.5 ms / 1.1 ms | 0.5 ms |

`tests/uop/test_grad.cpp` itself runs in about 1.7 s without sanitizers.
