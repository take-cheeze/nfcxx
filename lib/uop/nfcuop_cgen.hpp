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
// without a bound (Symbol::bound) keeps a malloc of its own.
//
// Symbols (stage 7, docs/notes/uop.md) make the loops dynamic when the renderer can write them: the loop bounds, the strides and
// the sizes of the buffers are then expressions in the run-time sizes of the symbols, which CModule::run reads from the feeds and
// checks against their bounds, so one program runs at any size up to them. A dimension that is a polynomial in the symbols (`N-1`,
// `2*N`) is an expression in the same sizes, checked at run time to be at least 1 and within its bound. Each dimension of a node says
// what it is (its SymDim in the UOp), so the renderer needs no representative size to find a symbol. A graph that needs a dimension the
// renderer does not know keeps integer loops (CProgram::dynamic is false).
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
  std::vector<std::string> syms;   // dynamic programs: the symbol of each dimension, "" for an integer or a polynomial; empty otherwise
  std::vector<Poly> dims;          // dynamic programs: each dimension as a polynomial in the symbols (an integer, a symbol or a polynomial);
                                   // empty otherwise
};
struct COutput {
  DType dtype;
  Shape shape;                     // the representative shape
  std::vector<std::string> syms;   // dynamic programs: the symbol of each dimension, as for CInput
  std::vector<Poly> dims;          // dynamic programs: each dimension as for CInput
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
    int64_t minimum = 1;        // the least size a run may give it (a cut of a symbolic dimension reads up to its end)
  };
  // Profiled programs (render_c with profile): one name per kernel, in the order of CModule::kernel_times.
  std::vector<std::string> kernel_names;
  bool dynamic = false;         // the loops take the symbols' sizes at run time
  std::vector<Symbol> symbols;  // dynamic: in name order; `sizes[k]` of nfcuop_run is the size of symbols[k]
  // Dynamic: a run-time condition, checked by CModule::run before any code runs. `value` evaluated at the sizes must be at least 0,
  // else the run is an Error that names `what`. The polynomial dimensions of the graph are at least 1 and within their bounds, and a cut
  // that ends at a polynomial (or at an integer, when its input is a polynomial) ends within the dimension it cuts.
  struct Check {
    Poly value;
    std::string what;
  };
  std::vector<Check> checks;
  int kernels = 0;              // loop nests generated
  int temporaries = 0;          // intermediate buffers (each one is in the arena or has a malloc of its own)
  int64_t arena_bytes = 0;      // the size of the one malloc'd arena holding the planned intermediates (0: none)
  int64_t naive_bytes = 0;      // the planned intermediates' sizes added up: what one buffer each would take
  int unplanned = 0;            // intermediates with a malloc of their own (their size depends on a symbol with no bound)
};

// Renders the graph of `roots` (several outputs share their common subgraph). Throws Error if two Vars of one name
// differ in dtype or shape. A dynamic program needs every symbol of the graph to name a dimension of an input (else the
// graph is rendered with integer loops).
// profile: each kernel is bracketed by clock reads (CLOCK_MONOTONIC, microseconds) that CModule::kernel_times reads back. The
// default source is unchanged, so a program rendered without profiling compiles as before.
CProgram render_c(const std::vector<const UOp*>& roots, bool profile = false);

// A compiled CProgram. The compiler is `cc` (a command line, split on spaces), or the environment variable NFCUOP_CC, or
// "cc"; the command `nfcxx` is also fine (docs/notes/uop.md). Compilation errors come back as an Error carrying the
// compiler's output.
class CModule {
 public:
  static std::shared_ptr<CModule> compile(const CProgram& program, const std::string& cc = "");
  // The values of the outputs; `feeds` must have every input of the program, with its dtype. A static program needs the
  // representative shapes. A dynamic one takes each symbol's size from the feeds: the sizes must agree, each is at least its
  // minimum and at most its bound (Error otherwise), and the outputs take the sizes too.
  std::vector<Array> run(const std::map<std::string, Array>& feeds) const;
  const CProgram& program() const { return prog_; }
  // Profiled modules only: the start and end of each kernel of the last run, in monotonic microseconds (the clock of
  // clock_gettime(CLOCK_MONOTONIC)), one entry per kernel of program().kernel_names.
  bool profiled() const { return prof_read_ != nullptr; }
  void kernel_times(std::vector<double>& begin, std::vector<double>& end) const;
  ~CModule();
  CModule(const CModule&) = delete;
  CModule& operator=(const CModule&) = delete;

 private:
  CModule() {}
  CProgram prog_;
  void* handle_ = nullptr;
  int (*fn_)(const void* const*, void* const*) = nullptr;                      // static programs
  int (*dyn_fn_)(const void* const*, void* const*, const int64_t*) = nullptr;  // dynamic programs
  int (*prof_count_)() = nullptr;                                             // profiled programs only
  void (*prof_read_)(double*, double*) = nullptr;
};

// One timed span of a C-backend np::Session run (NFCUOP_TRACE set): the whole run, named "run", or one kernel, named as in
// CProgram::kernel_names. run is the index of the run. Times are monotonic microseconds.
struct KernelTiming {
  std::string name;
  int run = 0;
  double ts_us = 0, dur_us = 0;
};

}  // namespace nfcuop
