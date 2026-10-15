// nfcuop tinygrad back end: a hir::Graph is exported with Graph::to_onnx and run by tinygrad (tinygrad.nn.onnx.OnnxRunner); the
// outputs come back as Arrays, the type the interpreter returns. tinygrad is Python only, so nothing here links against it or
// against CPython: both are found at run time.
//
//   nfcuop::hir::Graph g; ...                          // as for hir::Evaluator
//   std::vector<Array> out = nfcuop::tinygrad::run(g, {y}, {{"x", x_array}});
//
// Selected from the numpy API as a back end of eval: `np.backend = ut::Session::Backend::Tinygrad` (or `np.backend = "tinygrad"`
// from the scripting bindings). See docs/notes/uop.md.
//
// Two paths, with the same results:
//   embedded    the interpreter is started in this process: libpython is loaded with dlopen, and tinygrad and numpy are imported
//               once. The OnnxRunner of each model is kept. Tensors cross as bytes.
//   subprocess  scripts/tinygrad_run.py runs in a Python process per call; tensors cross as files in a scratch directory.
// The embedded path is used whenever it can be. When it cannot (no shared libpython, Py_Initialize failed, another libpython is
// loaded, tinygrad does not import, or the call is on another thread), the subprocess path is used, and an error from it says why.
//
// Environment:
//   NFCUOP_TINYGRAD_PYTHON     the Python executable (else python3); it must have tinygrad, numpy and onnx. Its libpython is the one
//                              loaded (its sysconfig LIBDIR and INSTSONAME, or LDLIBRARY).
//   NFCUOP_TINYGRAD_LIBPYTHON  the shared libpython to load, instead of the one of the executable.
//   NFCUOP_TINYGRAD_EMBED=0    always the subprocess path.
//   NFCUOP_TINYGRAD_SCRIPT     the helper script of the subprocess path (else scripts/tinygrad_run.py, relative to the working
//                              directory). The embedded path does not run it.
//
// The rules of the embedded interpreter (also in docs/notes/poly.md): one interpreter per process, never finalized. It is started by
// the first call that can start it, and it stays with the thread that started it (the GIL is not released, as in nfcpoly); a call from
// another thread takes the subprocess path. nfcpoly's Python backend, when it started the interpreter first, is reused.
#pragma once
#include <map>
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"

namespace nfcuop {
namespace tinygrad {

// Whether tinygrad can be imported: by the embedded interpreter, else by running the helper with --check. When neither can, `why`
// gets the reasons. Nothing that failed is cached, so a call after the environment changes asks again.
bool available(std::string* why = nullptr);

// The values of `outputs` (value ids of `g`) for the feeds (input name -> Array), as ort::run takes them. Throws Error when the
// feeds do not fit the graph, or when the model or tinygrad fails (the error has the Python traceback, or the helper's stderr).
// The outputs take the dtypes of the graph and the shapes tinygrad computed, so a symbolic dimension needs no binding.
std::vector<Array> run(const hir::Graph& g, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds);

// Which path the last run() took (None when it computed nothing: its outputs were inputs or initializers).
enum class Path { None, Embedded, Subprocess };
Path last_path();

// Why the embedded path was not used by the last call (empty when it was used).
std::string embedded_status();

// What this process has done on the embedded path: tinygrad imports, OnnxRunners built (one per model), and runs of each path.
struct Counts {
  int imports = 0;
  int runners = 0;
  int embedded_runs = 0;
  int subprocess_runs = 0;
};
Counts counts();

}  // namespace tinygrad
}  // namespace nfcuop
