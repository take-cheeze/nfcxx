// nfcuop ONNX Runtime backend: a hir::Graph is exported with Graph::to_onnx, run by ONNX Runtime and the outputs come back as
// Arrays, the same type the interpreter returns. ONNX Runtime is not a build dependency: the library is opened with dlopen at
// first use (the path is the environment variable NFCUOP_ORT_LIB; without it the common names libonnxruntime.so.1,
// libonnxruntime.so and libonnxruntime.dylib are tried), and the few C API declarations used are in nfcuop_ort.cpp.
//
//   nfcuop::hir::Graph g; ...                          // as for hir::Evaluator
//   std::vector<Array> out = nfcuop::ort::run(g, {y}, {{"x", x_array}});
//
// Selected from the numpy API as a back end of eval: `np.backend = ut::Session::Backend::Ort` (or `np.backend = "ort"` from
// the scripting bindings). See docs/notes/uop.md.
#pragma once
#include <map>
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"

namespace nfcuop {
namespace ort {

// Whether ONNX Runtime can be loaded (the first call loads it). When it cannot, `why` gets the reason.
bool available(std::string* why = nullptr);

// The values of `outputs` (value ids of `g`) for the feeds (input name -> Array). Every input that the outputs depend on
// needs a feed of its dtype and rank, and the feeds must agree on the sizes of a shared symbol. Returns the outputs in order,
// with the dtypes of the graph and the shapes ONNX Runtime computed. Throws Error when the library cannot be loaded, the
// feeds do not fit the graph, or ONNX Runtime refuses the model. Models are cached by their bytes (the sessions live until the
// process ends). Not thread safe, like the rest of nfcuop.
std::vector<Array> run(const hir::Graph& g, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds);

}  // namespace ort
}  // namespace nfcuop
