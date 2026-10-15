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
// The intermediate buffers (not the outputs, which the caller owns) share one malloc'd arena. Each one is live from the
// loop nest that writes it to the last loop nest that reads it, and the planner (nfcuop_arena.hpp, ported from onnxsim)
// gives it an offset so that buffers live at the same time do not overlap. An intermediate whose size depends on a symbol
// without a bound (RenderOptions) keeps a malloc of its own.
//
// Symbols (RenderOptions) make the loops dynamic when the renderer can write them: the loop bounds, the strides and the
// sizes of the buffers are then expressions in the run-time sizes of the symbols, which CModule::run reads from the feeds
// and checks against the bounds, so one program runs at any size up to them. A graph that needs a dimension the renderer
// does not know keeps integer loops (CProgram::dynamic is false). See docs/notes/uop.md, stage 7 step 2.
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
  Shape shape;                     // the representative shape (the one the program was rendered for)
  std::vector<std::string> syms;   // dynamic programs: the symbol of each dimension, "" for an integer; empty otherwise
};
struct COutput {
  DType dtype;
  Shape shape;                     // the representative shape
  std::vector<std::string> syms;   // dynamic programs: the symbol of each dimension, as for CInput
};

// Symbolic sizes (docs/notes/uop.md, stage 7 step 2). The UOp graph has concrete shapes, built at a representative size:
// `input_symbols["x"] = {"N", ""}` says that axis 0 of the input x is the symbol N and axis 1 is an integer (one entry per
// axis; "" for an integer axis). The representative size of N is the size x has in the graph. When the graph's loops can
// be written in the symbols (CProgram::dynamic), the program takes each symbol's size from the feeds of a run and runs at any
// size up to the bound. `symbol_bounds["N"] = 64` says that N is at most 64: the arena is sized from the bound (each
// intermediate's maximum size takes the bound for each symbolic dimension), and a run with a larger N throws Error. A symbol
// with no bound leaves its intermediates with a malloc of their own, of their run-time size. A graph whose loops need a
// dimension the renderer cannot place (see the notes) keeps integer loops: it runs only at its representative sizes. The
// graph must be built with each symbol written where its size is: a literal equal to a representative size is read as the
// symbol (the contract in the notes).
struct RenderOptions {
  std::map<std::string, std::vector<std::string>> input_symbols;
  std::map<std::string, int64_t> symbol_bounds;
};

struct CProgram {
  std::string source;           // C99; defines `int nfcuop_run(in, out)` (0 on success), or when dynamic
                                // `int nfcuop_run(in, out, const int64_t* sizes)`, one size per entry of `symbols`
  std::vector<CInput> inputs;   // the Vars of the graphs, sorted by name; `in` holds their buffers in this order
  std::vector<COutput> outputs; // `out` holds the output buffers in the order of the roots given to render_c
  struct Symbol {
    std::string name;
    int64_t size = 0;           // the representative size (the size in the graph)
    int64_t bound = 0;          // the bound, or 0 when there is none
  };
  bool dynamic = false;         // the loops take the symbols' sizes at run time
  std::vector<Symbol> symbols;  // dynamic: in name order; `sizes[k]` of nfcuop_run is the size of symbols[k]
  int kernels = 0;              // loop nests generated
  int temporaries = 0;          // intermediate buffers (each one is in the arena or has a malloc of its own)
  int64_t arena_bytes = 0;      // the size of the one malloc'd arena holding the planned intermediates (0: none)
  int64_t naive_bytes = 0;      // the planned intermediates' sizes added up: what one buffer each would take
  int unplanned = 0;            // intermediates with a malloc of their own (their size depends on a symbol with no bound)
};

// Renders the graph of `roots` (several outputs share their common subgraph). Throws Error if two Vars of one name
// differ in dtype or shape, or if `options` does not fit the graph (an unknown input, a wrong rank, a bound below 1, an
// input larger than its bound).
CProgram render_c(const std::vector<const UOp*>& roots, const RenderOptions& options = RenderOptions());

// A compiled CProgram. The compiler is `cc` (a command line, split on spaces), or the environment variable NFCUOP_CC, or
// "cc"; the command `nfcxx` is also fine (docs/notes/uop.md). Compilation errors come back as an Error carrying the
// compiler's output.
class CModule {
 public:
  static std::shared_ptr<CModule> compile(const CProgram& program, const std::string& cc = "");
  // The values of the outputs; `feeds` must have every input of the program, with its dtype. A static program needs the
  // representative shapes. A dynamic one takes each symbol's size from the feeds: the sizes must agree, each is at least 1
  // and at most its bound (Error otherwise), and the outputs take the sizes too.
  std::vector<Array> run(const std::map<std::string, Array>& feeds) const;
  const CProgram& program() const { return prog_; }
  ~CModule();
  CModule(const CModule&) = delete;
  CModule& operator=(const CModule&) = delete;

 private:
  CModule() {}
  CProgram prog_;
  void* handle_ = nullptr;
  int (*fn_)(const void* const*, void* const*) = nullptr;                      // static programs
  int (*dyn_fn_)(const void* const*, void* const*, const int64_t*) = nullptr;  // dynamic programs
};

}  // namespace nfcuop
