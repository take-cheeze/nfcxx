// nfcuop::hir::gradients: reverse-mode automatic differentiation on the ONNX-style graph (nfcuop_hir.hpp). The gradient is
// built as more nodes of the same graph, from ONNX operators only, so it can be exported with Graph::to_onnx, checked with
// onnx.checker, run by onnxruntime, lowered and evaluated like any other value (and differentiated again).
//
//   int loss = ...;                                           // a float scalar value of `g`
//   std::vector<int> d = hir::gradients(g, loss, {w1, b1});   // d[k] has the shape and dtype of wrt[k]
//
// Operators with a rule: Identity Cast(float to float) Neg Abs Relu Sqrt Exp Log Sin Cos Tanh Sigmoid Add Sub Mul Div Max Min
// Where Clip MatMul Transpose Reshape Squeeze Unsqueeze Expand ReduceSum ReduceMean ReduceMax ReduceMin Softmax LogSoftmax Slice
// Concat Pad. Comparisons, logic, Mod and everything that is bool or integer are constants for the gradient (their derivative
// is zero where it exists); a gradient that would have to flow into an integer value that depends on a `wrt` is an Error.
// The tie conventions are in docs/notes/uop-autodiff.md.
#pragma once
#include <vector>

#include "nfcuop_hir.hpp"

namespace nfcuop {
namespace hir {

// d `loss` / d `wrt[k]` for each k, as values of `g` (new nodes are appended to `g`). `loss` must be a float value with an
// empty shape; every `wrt` must be a float value (an input, an initializer or any node's output). A `wrt` the loss does not
// depend on gets a zero constant of its shape. Throws Error for a loss that is not a float scalar, an integer `wrt`, an
// operator without a rule on the path from a `wrt` to the loss, and for a path through a float-to-integer cast.
std::vector<int> gradients(Graph& g, int loss, const std::vector<int>& wrt);

}  // namespace hir
}  // namespace nfcuop
