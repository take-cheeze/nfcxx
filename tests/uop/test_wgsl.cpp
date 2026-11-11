// nfcuop WGSL rendering (nfcuop_wgsl.hpp): the generated module matches a golden text, the unsupported graphs are refused,
// and the cases for the WebGPU runner (tests/uop/wgsl/run.sh) are written to the directory given as argv[1].
// NFCUOP_UPDATE_GOLDEN=1 rewrites the golden file.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "nfcuop_wgsl.hpp"

using namespace nfcuop;

static int checks = 0, failed = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond)) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
#define CHECK_THROWS(expr)                                                 \
  do {                                                                     \
    checks++;                                                              \
    bool threw_ = false;                                                   \
    try { (void)(expr); } catch (const Error&) { threw_ = true; }          \
    if (!threw_) { failed++; std::printf("FAIL %s:%d: no Error from %s\n", __FILE__, __LINE__, #expr); } \
  } while (0)

static const char* kGolden = "tests/uop/golden/wgsl_add_mul_reduce.wgsl";

// The inputs of the graphs: deterministic values with both signs.
static Array input(const Shape& shape, double base, double step) {
  std::vector<double> v;
  for (int64_t i = 0; i < numel(shape); i++) v.push_back(base + step * static_cast<double>(i));
  return Array::from_doubles(DType::Float32, shape, v);
}

// One JS line per array: the values as they print in %.9g (a Float32 reads back exactly).
static std::string js_array(const Array& a) {
  std::string s = "[";
  for (size_t i = 0; i < a.data.size(); i++) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.9g", a.data[i].f);
    s += (i ? "," : "") + std::string(buf);
  }
  return s + "]";
}

// Writes `window.CASE = {...}` for the runner: the module, its buffers and kernels, the inputs by name, and the
// interpreter's result.
static void write_case(const std::string& path, const WgslProgram& p, const UOp* root,
                       const std::map<std::string, Array>& vars) {
  std::ofstream f(path);
  f << "window.CASE = {\n  source: " << "`" << p.source << "`,\n";
  f << "  buffers: [";
  for (size_t b = 0; b < p.buffers.size(); b++)
    f << (b ? ", " : "") << "{name: \"" << p.buffers[b].name << "\", count: " << p.buffers[b].count
      << ", input: " << (p.buffers[b].input ? "true" : "false") << "}";
  f << "],\n  kernels: [";
  for (size_t k = 0; k < p.kernels.size(); k++) {
    const WgslKernel& kr = p.kernels[k];
    f << (k ? ", " : "") << "{entry: \"" << kr.entry << "\", out: " << kr.out << ", count: " << kr.count
      << ", bindings: [";
    for (size_t j = 0; j < kr.bindings.size(); j++) f << (j ? ", " : "") << kr.bindings[j];
    f << "]}";
  }
  f << "],\n  output: " << p.output << ",\n  inputs: {";
  bool first = true;
  for (const auto& [name, arr] : vars) {
    f << (first ? "" : ", ") << name << ": " << js_array(arr);
    first = false;
  }
  Array want = evaluate_array(root, vars);
  f << "},\n  expected: " << js_array(want) << "\n};\n";
}

int main(int argc, char** argv) {
  // Graph A: a reduction over the sum of x and y scaled by 2, the shape of a reduce after elementwise ops.
  Graph ga;
  const UOp* x = ga.var("x", DType::Float32, {2, 3});
  const UOp* y = ga.var("y", DType::Float32, {2, 3});
  const UOp* two = ga.fconst(DType::Float32, 2.0, {2, 3});
  const UOp* root_a = ga.reduce_sum(ga.mul(ga.add(x, y), two), {1});

  WgslProgram pa = render_wgsl(root_a);
  CHECK(pa.kernels.size() == 3);   // add, mul, reduce: one kernel per node
  CHECK(pa.output == pa.buffers.size() - 1);
  CHECK(pa.shape == (Shape{2, 1}));

  // The golden text. NFCUOP_UPDATE_GOLDEN=1 writes it.
  if (std::getenv("NFCUOP_UPDATE_GOLDEN")) {
    std::ofstream(kGolden) << pa.source;
    std::printf("wrote %s\n", kGolden);
  } else {
    std::ifstream g(kGolden);
    std::stringstream ss;
    ss << g.rdbuf();
    CHECK(g.good());
    CHECK(ss.str() == pa.source);
  }

  // Graph B: every elementwise op the renderer has, on the same inputs, and a sqrt of a sum of squares.
  Graph gb;
  const UOp* bx = gb.var("x", DType::Float32, {2, 3});
  const UOp* by = gb.var("y", DType::Float32, {2, 3});
  const UOp* one = gb.fconst(DType::Float32, 1.0, {2, 3});
  const UOp* norm = gb.sqrt(gb.add(gb.mul(bx, bx), one));
  const UOp* root_b = gb.fdiv(gb.sub(gb.max(bx, by), gb.neg(by)), norm);
  WgslProgram pb = render_wgsl(root_b);
  CHECK(pb.kernels.size() == 7);

  // The graphs the renderer refuses: movement ops, other dtypes, a leaf as the root.
  Graph gr;
  const UOp* rx = gr.var("x", DType::Float32, {2, 3});
  CHECK_THROWS(render_wgsl(gr.permute(rx, {1, 0})));
  CHECK_THROWS(render_wgsl(gr.cast(rx, DType::Int32)));
  CHECK_THROWS(render_wgsl(rx));
  const UOp* rd = gr.var("d", DType::Float64, {2});
  CHECK_THROWS(render_wgsl(gr.add(rd, rd)));

  if (argc > 1) {
    const std::string dir = argv[1];
    std::map<std::string, Array> vars_a{{"x", input({2, 3}, -0.7, 0.1)}, {"y", input({2, 3}, 1.3, -0.2)}};
    std::map<std::string, Array> vars_b{{"x", input({2, 3}, -0.9, 0.35)}, {"y", input({2, 3}, 0.6, 0.25)}};
    write_case(dir + "/case_reduce.js", pa, root_a, vars_a);
    write_case(dir + "/case_elementwise.js", pb, root_b, vars_b);
  }

  std::printf("%d checks, %d failed\n", checks, failed);
  return failed ? 1 : 0;
}
