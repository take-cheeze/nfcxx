// nfcuop WGSL rendering: UOp graphs to a WebGPU compute shader (WGSL), run through WebGPU (on macOS, Metal underneath).
//
//   nfcuop::WgslProgram p = nfcuop::render_wgsl(root);   // the WGSL module, its buffers and its kernels
//
// What it renders (a first slice; see docs/notes/uop-wgsl.md): Float32 nodes with the elementwise ALU ops Neg, Sqrt,
// Add, Sub, Mul, FDiv and Max, and ReduceSum. Each such node is one kernel with its own storage buffer; there is no
// fusion, so a node is computed once and read back by its users. Var nodes are input buffers and Const nodes are literals.
// Movement ops and the other dtypes are refused with Error.
//
// The kernels run in order (WgslProgram::kernels), and each one writes its buffer. A ReduceSum kernel starts from the
// first element of its reduced axes and adds the rest in row-major order, as the interpreter does (evaluate_array). Its
// elementwise results are the WGSL f32 results: WGSL does not require correctly rounded sqrt or division, so a GPU result
// can differ from the interpreter in the last bit; the runner compares within a tolerance.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

#include "nfcuop.hpp"

namespace nfcuop {

// One storage buffer of the module. Buffers are bound at group 0, binding = index in WgslProgram::buffers.
struct WgslBuffer {
  std::string name;  // the Var name for an input, "b<id>" for a node's result
  int64_t count;     // the number of f32 elements
  bool input;
};
// One compute entry point: it fills buffers[out] for `count` elements (one invocation per element).
struct WgslKernel {
  std::string entry;              // "k<id>"
  size_t out;                     // index into buffers
  int64_t count;
  std::vector<size_t> bindings;   // the buffers the entry reads or writes (a kernel binds only these: a WebGPU stage
                                  // allows 8 storage buffers, and a graph can have more)
};
struct WgslProgram {
  std::string source;  // the WGSL module
  std::vector<WgslBuffer> buffers;
  std::vector<WgslKernel> kernels;  // in dependency order
  size_t output;                    // index of the root's buffer
  Shape shape;                      // the root's shape
};

// The WGSL module computing `root` (which must be an operation, not a leaf). Throws Error on anything it does not render.
WgslProgram render_wgsl(const UOp* root);

}  // namespace nfcuop
