// nfcuop tinygrad back end: a hir::Graph is exported with Graph::to_onnx and written to a scratch directory with its feeds; the
// Python helper scripts/tinygrad_run.py runs it with tinygrad (tinygrad.nn.onnx.OnnxRunner) and writes the outputs back, and
// they come back as Arrays, the type the interpreter returns. tinygrad is Python only, so nothing here links against it.
//
//   nfcuop::hir::Graph g; ...                          // as for hir::Evaluator
//   std::vector<Array> out = nfcuop::tinygrad::run(g, {y}, {{"x", x_array}});
//
// Selected from the numpy API as a back end of eval: `np.backend = ut::Session::Backend::Tinygrad` (or `np.backend = "tinygrad"`
// from the scripting bindings). See docs/notes/uop.md.
//
// The Python executable is $NFCUOP_TINYGRAD_PYTHON (else python3); it must have tinygrad, numpy and onnx. The helper script is
// $NFCUOP_TINYGRAD_SCRIPT (else scripts/tinygrad_run.py, relative to the working directory).
#pragma once
#include <map>
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"

namespace nfcuop {
namespace tinygrad {

// Whether the helper can import tinygrad, by running it with --check. When it cannot, `why` gets the helper's error text.
// Nothing is cached, so a call after the environment changes asks again.
bool available(std::string* why = nullptr);

// The values of `outputs` (value ids of `g`) for the feeds (input name -> Array), as ort::run takes them. Throws Error when the
// feeds do not fit the graph, the helper cannot be started, or it fails (the error has the helper's stderr). Every call starts
// one Python process; nothing is cached. The outputs take the dtypes of the graph and the shapes tinygrad computed, so a
// symbolic dimension needs no binding.
std::vector<Array> run(const hir::Graph& g, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds);

}  // namespace tinygrad
}  // namespace nfcuop
