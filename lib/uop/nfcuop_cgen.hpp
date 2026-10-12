// nfcuop C rendering (stage 4): UOp graphs to a C program, compiled with a C compiler and run.
//
//   nfcuop::CProgram p = nfcuop::render_c({root});          // the C source and the buffer layout
//   auto m = nfcuop::CModule::compile(p);                    // cc -shared, dlopen
//   std::vector<nfcuop::Array> out = m->run({{"x", arr}});   // inputs by Var name
//
// What the renderer does: nodes are fused into loop nests. Elementwise ops, casts, `Where` and the movement ops
// (Reshape, Permute, Expand, Shrink, Pad, Flip) are expressions in the loop variables (a movement op rewrites the
// index; Pad becomes a bounds test), so a chain of them is one loop nest with no temporaries. A reduction is a loop
// nest of its own that accumulates over the reduced axes in row-major order, with the fused producer of its source
// inside the loop. A node is materialized in a buffer when it is a reduction, a graph output, or when it is used more
// than once and is more than an index change of something already stored (so shared subexpressions are computed once
// and the generated code cannot grow exponentially).
//
// The generated code computes what the interpreter (evaluate_array) computes, bit for bit: integers wrap
// (unsigned arithmetic), a Float32 node is rounded to float after every op, exp2/log2/sin run in double and are rounded,
// float-to-int casts saturate and map NaN to 0, a reduction starts from its first element, and sums run in the same
// order. The one difference: an integer division or modulo by zero gives 0 here (the interpreter throws).
// See docs/notes/uop.md.
#pragma once
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "nfcuop.hpp"

namespace nfcuop {

struct CInput {
  std::string name;
  DType dtype;
  Shape shape;
};
struct COutput {
  DType dtype;
  Shape shape;
};

struct CProgram {
  std::string source;           // C99; defines `int nfcuop_run(const void* const* in, void* const* out)` (0 on success)
  std::vector<CInput> inputs;   // the Vars of the graphs, sorted by name; `in` holds their buffers in this order
  std::vector<COutput> outputs; // `out` holds the output buffers in the order of the roots given to render_c
  int kernels = 0;              // loop nests generated
  int temporaries = 0;          // buffers allocated for materialized intermediates
};

// Renders the graph of `roots` (several outputs share their common subgraph). Throws Error if two Vars of one name
// differ in dtype or shape.
CProgram render_c(const std::vector<const UOp*>& roots);

// A compiled CProgram. The compiler is `cc` (a command line, split on spaces), or the environment variable NFCUOP_CC, or
// "cc"; the command `nfcxx` is also fine (docs/notes/uop.md). Compilation errors come back as an Error carrying the
// compiler's output.
class CModule {
 public:
  static std::shared_ptr<CModule> compile(const CProgram& program, const std::string& cc = "");
  // The values of the outputs; `feeds` must have every input of the program, with its dtype and shape.
  std::vector<Array> run(const std::map<std::string, Array>& feeds) const;
  const CProgram& program() const { return prog_; }
  ~CModule();
  CModule(const CModule&) = delete;
  CModule& operator=(const CModule&) = delete;

 private:
  CModule() {}
  CProgram prog_;
  void* handle_ = nullptr;
  int (*fn_)(const void* const*, void* const*) = nullptr;
};

}  // namespace nfcuop
