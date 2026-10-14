// nfcuop::hir::gradients_via_onnxsim: reverse-mode automatic differentiation by onnxsim's ONNX-level autograd
// (onnxsim at the commit of scripts/setup-onnxsim.sh, graph_grad), not by rules of our own. The sub-graph of the loss is exported with Graph::to_onnx, onnxsim
// appends the gradient as ordinary ONNX nodes, and the result is merged back into the same graph (Graph::merge_onnx): the
// gradients are values of `g` like any other, lowered and evaluated by both back ends and exported next to the loss.
//
//   int loss = ...;                                                       // a float scalar value of `g`
//   std::vector<int> d = hir::gradients_via_onnxsim(g, loss, {w1, b1});   // d[k] has the shape and dtype of wrt[k]
//
// Two ways to reach onnxsim, tried in this order (docs/notes/uop-autodiff.md):
//   1. libnfconnxsim.so, built by scripts/setup-onnxsim.sh from onnxsim's C++ sources and loaded with dlopen on first use
//      (path: $NFCUOP_ONNXSIM, else build/onnxsim/ relative to the working directory or to this file's repository);
//   2. the Python package: `$NFCUOP_PYTHON scripts/onnx_grad.py` (default python3; the script: $NFCUOP_ONNX_GRAD or
//      scripts/onnx_grad.py) as a subprocess with temporary files, which needs `pip install onnx onnxsim==0.8.1`.
// $NFCUOP_ONNXSIM_BACKEND=library|python forces one of them. Nothing of Python, onnx or protobuf is linked into nfcuop.
//
// onnxsim's C++ rules cover: Add Sub Mul Div Neg Relu Sqrt Exp Log Sigmoid Tanh Erf Clip MatMul Gemm Transpose Reshape
// Identity ReduceSum ReduceMean Softmax Gather Conv MaxPool AveragePool BatchNormalization InstanceNormalization
// LayerNormalization; of these hir has Add Sub Mul Div Neg Relu Sqrt Exp Log Sigmoid Tanh Clip MatMul Transpose Reshape
// Identity ReduceSum ReduceMean Softmax. An operator without a rule on the path from a `wrt` to the loss is an Error carrying
// the library's message.
#pragma once
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"

namespace nfcuop {
namespace hir {

// d `loss` / d `wrt[k]` for each k, as values of `g` (new nodes are appended to `g`). `loss` must be a float value with an
// empty shape; every `wrt` must be a float value (an input, an initializer or any node's output). A `wrt` the loss does not
// depend on gets a zero constant of its shape. Throws Error for a loss that is not a float scalar, a `wrt` that is not float,
// an operator without a rule, when onnxsim cannot be reached, and for any failure of onnxsim (with its message).
std::vector<int> gradients_via_onnxsim(Graph& g, int loss, const std::vector<int>& wrt);

// Whether gradients_via_onnxsim can run here. True: *info says which way ("library <path>" or "python <command>"). False:
// *info says what was tried. The answer is computed once per process.
bool onnxsim_available(std::string* info = nullptr);

}  // namespace hir
}  // namespace nfcuop
