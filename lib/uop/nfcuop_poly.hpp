// nfcuop::poly: the numpy-like API (nfcuop_np.hpp) for scripts, through nfcpoly (lib/poly). A script in Ruby, Lua, Python,
// JavaScript or Go builds tensor graphs, evaluates them and exports ONNX with the same calls the C++ API has:
//
//   nfcuop::np::Session session;
//   nfcpoly::Context ctx;
//   nfcuop::poly::bind_numpy(ctx, session);              // the global `np`, and the class Tensor
//   ctx.eval_void("python", R"(
//     w = np.array([[1, 2], [3, 4]]); x = np.placeholder('x', [2, 2])
//     y = np.softmax(x @ w + 1.0)                        # operators work where the language has them
//     print(np.eval(y, [['x', [[1, 0], [0, 1]]]]))       # nested lists in and out
//     np.save_onnx('m.onnx', [['y', y]])                 # or np.to_onnx(...), the bytes
//   )");
//
// The same script in the other languages differs only in syntax (Ruby `np.softmax(x.matmul(w) + 1.0)`, Lua `np:softmax(x:matmul(w) + 1.0)`, JavaScript
// `np.softmax(x.matmul(w).add(1.0))`, Go `np.Softmax(x.Matmul(w).Add(1.0))`). What each language gets, the operator table and
// the conventions (dtype names, shapes, feeds, indexing) are in docs/notes/uop-poly.md.
//
// The Session and everything made from it must outlive the Context's scripts: tensors in scripts refer to the Session.
#pragma once
#include <string>

#include "nfcpoly.hpp"
#include "nfcuop_np.hpp"

namespace nfcuop {
namespace poly {

// Defines the script classes Tensor and NumPy in `ctx` and the global NAME (default "np"), a NumPy object for `session`.
// A C++ nfcuop::Error thrown by a call arrives in the script as the language's host error with the same message (and, if the
// script does not rescue it, comes out of eval() as the nfcuop::Error itself).
void bind_numpy(nfcpoly::Context& ctx, np::Session& session, const std::string& name = "np");

}  // namespace poly
}  // namespace nfcuop
