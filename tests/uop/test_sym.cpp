// Symbolic dimensions in the ONNX-style graph (hir::Graph, nfcuop_hir.hpp): an input's dimension may be a symbol (ONNX dim_param,
// e.g. "N"), and an operator may derive a polynomial in symbols (4*N, N+1: onnxsim's SymExpr, nfcuop_sym_expr.hpp). Shape inference
// follows ONNX's broadcasting and reshape rules and refuses what it cannot represent; the exporter writes
// dim_param and the reader takes it back; hir::Evaluator binds the symbols to sizes, lowers the bound graph once per binding and
// evaluates it. The MLP's expected values are worked out by hand (the comments show the sums). With a directory as argv[1] the
// models are also written for tests/uop/onnx_check.py (onnx.checker and onnxruntime, at each batch size).
#include <cstdio>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"

using namespace nfcuop;

static int checks = 0, failed = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond)) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
// the statement must throw an Error whose message contains `frag`
#define CHECK_ERR(expr, frag)                                              \
  do {                                                                     \
    checks++;                                                              \
    std::string msg_;                                                      \
    bool threw_ = false;                                                   \
    try { (void)(expr); } catch (const Error& e) { threw_ = true; msg_ = e.what(); } \
    if (!threw_ || msg_.find(frag) == std::string::npos) { failed++; std::printf("FAIL %s:%d: %s: error \"%s\" lacks \"%s\"\n", __FILE__, __LINE__, #expr, msg_.c_str(), frag); } \
  } while (0)

using V = std::vector<double>;
static const DType f32 = DType::Float32, i64 = DType::Int64;
static hir::Dim S(const std::string& s) { return hir::Dim::symbol(s); }
static Array arr(DType d, const Shape& s, const V& v) { return Array::from_doubles(d, s, v); }
static V vals(const Array& a) { V v; for (const Scalar& s : a.data) v.push_back(s.as_double()); return v; }
static V zeros(size_t n) { return V(n, 0.0); }

// x: [N, 2, 2] -> Reshape [0, 4] -> [N, 4] -> MatMul w1 [4, 3] -> Add b1 -> Relu -> MatMul w2 [3, 2] -> Add b2 -> y: [N, 2]
static hir::Graph mlp(int* out) {
  hir::Graph g;
  int x = g.add_symbolic_input("x", f32, hir::Dims{S("N"), 2, 2});
  int shape = g.add_initializer("shape", arr(i64, {2}, {0, 4}));
  int r = g.add_node("Reshape", {x, shape});
  int w1 = g.add_initializer("w1", arr(f32, {4, 3}, {1, 0, -1, 0, 1, 1, 2, -1, 0, 1, 1, 1}));
  int b1 = g.add_initializer("b1", arr(f32, {3}, {0.5, -4, 0.25}));
  int w2 = g.add_initializer("w2", arr(f32, {3, 2}, {1, 2, -1, 0, 0, 1}));
  int b2 = g.add_initializer("b2", arr(f32, {2}, {1, -0.5}));
  int m1 = g.add_node("MatMul", {r, w1});
  int a1 = g.add_node("Add", {m1, b1});
  int h = g.add_node("Relu", {a1});
  int m2 = g.add_node("MatMul", {h, w2});
  *out = g.add_node("Add", {m2, b2}, {}, "y");
  return g;
}

// the inputs for the batch sizes: rows [1,2,3,4] and [5,6,7,8], then (for 3) a row of zeros
static Array batch_input(int n) {
  V v = {1, 2, 3, 4, 5, 6, 7, 8};
  for (int k = 2; k < n; k++) for (int j = 0; j < 4; j++) v.push_back(0);
  return arr(f32, {n, 2, 2}, v);
}

static void symbolic_mlp(const std::string& dir) {
  int y = -1;
  hir::Graph g = mlp(&y);
  CHECK(g.symbols() == std::vector<std::string>{"N"});
  CHECK(g.dims(y) == (hir::Dims{S("N"), 2}));
  CHECK(g.value(y).shape == (Shape{0, 2}) && g.symbolic(y));
  CHECK(!g.symbolic(g.find_value("w1")));
  CHECK(g.str().find("float32[N,2,2]") != std::string::npos);

  // the hand values: row [1,2,3,4] -> hidden [11.5, 0, 5.25] -> out [12.5, 27.75]; row [5,6,7,8] -> hidden [27.5, 3, 9.25] -> [25.5, 63.75];
  // the zero row -> hidden [0.5, 0, 0.25] -> [1.5, 0.75]
  hir::Evaluator ev(g);
  std::map<std::string, Array> feeds2 = {{"x", batch_input(2)}};
  std::vector<Array> r2 = ev.eval({{"N", 2}}, {y}, feeds2);
  CHECK(r2.size() == 1 && r2[0].shape == (Shape{2, 2}) && vals(r2[0]) == (V{12.5, 27.75, 25.5, 63.75}));
  std::map<std::string, Array> feeds3 = {{"x", batch_input(3)}};
  std::vector<Array> r3 = ev.eval({{"N", 3}}, {y}, feeds3);
  CHECK(r3.size() == 1 && r3[0].shape == (Shape{3, 2}) && vals(r3[0]) == (V{12.5, 27.75, 25.5, 63.75, 1.5, 0.75}));
  CHECK(ev.bindings_lowered() == 2);
  // the same binding is cached: no new lowering, the same values again
  std::vector<Array> again = ev.eval({{"N", 2}}, {y}, feeds2);
  CHECK(ev.bindings_lowered() == 2 && vals(again[0]) == vals(r2[0]));
  // a feed of another size is refused, and so is a binding that is not a symbol of the graph or is below 1
  CHECK_ERR(ev.eval({{"N", 2}}, {y}, {{"x", batch_input(3)}}), "feed for x");
  CHECK_ERR(ev.eval({{"N", 2}, {"M", 1}}, {y}, feeds2), "no symbol M");
  CHECK_ERR(ev.eval({{"N", 0}}, {y}, feeds2), "below 1");
  CHECK_ERR(ev.eval({}, {y}, feeds2), "has no binding");

  // binding gives a static graph with the same value ids; lowering a symbolic value without a binding is an Error
  hir::Graph b = g.bind({{"N", 2}});
  CHECK(b.dims(y) == (hir::Dims{2, 2}) && !b.symbolic(y) && b.symbols().empty() && b.num_values() == g.num_values());
  ut::Session s;
  hir::Lowerer low(g, s);
  CHECK_ERR(low.get(y), "bound");
  hir::Lowerer lowb(b, s);
  CHECK(lowb.get(y).shape() == (Shape{2, 2}));

  // export: dim_param for the symbolic dimensions (field 2 of Dimension, "N"), and the reader takes it back
  std::string bytes = g.to_onnx({y});
  CHECK(bytes.find(std::string("\x12\x01N", 3)) != std::string::npos);
  std::vector<int> outs;
  hir::Graph back = hir::Graph::from_onnx(bytes, &outs);
  CHECK(outs.size() == 1 && back.dims(back.find_value("x")) == (hir::Dims{S("N"), 2, 2}) && back.dims(outs[0]) == (hir::Dims{S("N"), 2}));
  CHECK(back.to_onnx(outs) == bytes);
  CHECK(hir::Evaluator(back).eval({{"N", 3}}, outs, feeds3)[0].shape == (Shape{3, 2}));

  if (!dir.empty()) {
    // the same model for two batch sizes, with the interpreter's outputs for onnx_check.py (it reads NAME.json next to NAME.onnx)
    auto write = [&](const std::string& path, const std::string& data) { std::ofstream f(path, std::ios::binary); f.write(data.data(), static_cast<std::streamsize>(data.size())); };
    auto jarr = [](const Array& a) {
      std::string o = "{\"dtype\":\"" + std::string(name(a.dtype)) + "\",\"shape\":[";
      for (size_t k = 0; k < a.shape.size(); k++) o += (k ? "," : "") + std::to_string(a.shape[k]);
      o += "],\"data\":[";
      for (size_t k = 0; k < a.data.size(); k++) o += (k ? "," : "") + std::to_string(a.data[k].f);
      return o + "]}";
    };
    const struct { std::string file; int n; std::vector<Array>* res; std::map<std::string, Array>* in; } cases[] = {
        {"symbolic_mlp_2", 2, &r2, &feeds2}, {"symbolic_mlp_3", 3, &r3, &feeds3}};
    for (const auto& c : cases) {
      write(dir + "/" + c.file + ".onnx", bytes);
      std::string j = "{\"inputs\":{\"x\":" + jarr(c.in->at("x")) + "},\"outputs\":{\"y\":" + jarr((*c.res)[0]) + "}}";
      write(dir + "/" + c.file + ".json", j);
    }
  }
}

// Shape inference: the results for symbols, and the refusals. `e` has the inputs below.
static void shape_inference() {
  hir::Graph e;
  int a = e.add_symbolic_input("a", f32, hir::Dims{S("N"), 4});
  int b = e.add_symbolic_input("b", f32, hir::Dims{S("M"), 4});
  int x3 = e.add_symbolic_input("x3", f32, hir::Dims{S("N"), 2, 2});
  int c34 = e.add_initializer("", arr(f32, {3, 4}, zeros(12)));
  int row = e.add_initializer("", arr(f32, {1, 4}, {1, 2, 3, 4}));
  auto ints = [&](const Shape& s, const V& v) { return e.add_initializer("", arr(i64, s, v)); };

  // broadcasting: a symbol against itself or 1 (N), anything else is an Error
  CHECK(e.dims(e.add_node("Add", {a, row})) == (hir::Dims{S("N"), 4}));
  CHECK_ERR(e.add_node("Add", {a, b}), "cannot be broadcast");
  CHECK_ERR(e.add_node("Add", {a, c34}), "cannot be broadcast");
  CHECK(e.dims(e.add_node("Mul", {a, a})) == (hir::Dims{S("N"), 4}));
  CHECK(e.dims(e.add_node("Where", {e.add_node("Less", {a, row}), a, row})) == (hir::Dims{S("N"), 4}));

  // reshape: 0 copies the symbol, -1 is the exact quotient of the sizes (N*4 / 4 is N; a quotient that is not a polynomial is refused)
  CHECK(e.dims(e.add_node("Reshape", {x3, ints({2}, {0, 4})})) == (hir::Dims{S("N"), 4}));
  CHECK(e.dims(e.add_node("Reshape", {x3, ints({2}, {-1, 4})})) == (hir::Dims{S("N"), 4}));
  CHECK(e.dims(e.add_node("Reshape", {x3, ints({3}, {-1, 2, 2})})) == (hir::Dims{S("N"), 2, 2}));
  CHECK(e.dims(e.add_node("Reshape", {e.add_symbolic_input("v", f32, hir::Dims{S("N")}), ints({1}, {-1})})) == (hir::Dims{S("N")}));
  CHECK(e.dims(e.add_node("Reshape", {a, ints({1}, {-1})})) == (hir::Dims{S("N") * 4}));   // [N,4] -> [N*4]
  CHECK(e.dims(e.add_node("Reshape", {x3, ints({2}, {2, -1})})) == (hir::Dims{2, S("N") * 2}));
  CHECK_ERR(e.add_node("Reshape", {x3, ints({2}, {-1, 3})}), "cannot reshape");   // 4N is not a multiple of 3
  CHECK_ERR(e.add_node("Reshape", {x3, ints({2}, {4, 4})}), "cannot reshape");
  CHECK_ERR(e.add_node("Reshape", {a, ints({2}, {3, 4})}), "cannot reshape");     // [N,4] -> [3,4]: 4N is not 12 for every N

  // matmul and gemm: the contraction axes must be equal; the rows (and the batch) pass through
  int w42 = e.add_initializer("", arr(f32, {4, 2}, zeros(8)));
  CHECK(e.dims(e.add_node("MatMul", {a, w42})) == (hir::Dims{S("N"), 2}));
  CHECK_ERR(e.add_node("MatMul", {a, c34}), "do not align");
  int w43 = e.add_initializer("", arr(f32, {4, 3}, zeros(12)));
  CHECK(e.dims(e.add_node("Gemm", {a, w43, e.add_initializer("", arr(f32, {3}, zeros(3)))})) == (hir::Dims{S("N"), 3}));
  CHECK_ERR(e.add_node("Gemm", {a, e.add_initializer("", arr(f32, {5, 3}, zeros(15)))}), "do not align");

  // reductions drop or keep a symbolic axis; a reduction over the symbol gives its size as 1 (no value of N is needed)
  CHECK(e.dims(e.add_node("ReduceSum", {a, ints({1}, {0})}, {hir::Attribute::Int("keepdims", 0)})) == (hir::Dims{4}));
  CHECK(e.dims(e.add_node("ReduceMean", {a, ints({1}, {1})}, {hir::Attribute::Int("keepdims", 1)})) == (hir::Dims{S("N"), 1}));

  // concat along the symbol adds the sizes (N + N is 2*N, N + M and N + 1 are polynomials); along another axis it passes
  CHECK(e.dims(e.add_node("Concat", {a, a}, {hir::Attribute::Int("axis", 0)})) == (hir::Dims{S("N") * 2, 4}));
  CHECK(e.dims(e.add_node("Concat", {a, b}, {hir::Attribute::Int("axis", 0)})) == (hir::Dims{S("N") + S("M"), 4}));
  CHECK(e.dims(e.add_node("Concat", {a, row}, {hir::Attribute::Int("axis", 0)})) == (hir::Dims{S("N") + 1, 4}));
  CHECK(e.dims(e.add_node("Concat", {a, a}, {hir::Attribute::Int("axis", 1)})) == (hir::Dims{S("N"), 8}));

  // slicing the symbol is refused (its size would be needed); another axis is fine. Padding adds to the symbol: N + 1
  CHECK_ERR(e.add_node("Slice", {a, ints({1}, {0}), ints({1}, {1}), ints({1}, {0})}), "slicing the symbolic dimension N");
  CHECK(e.dims(e.add_node("Slice", {a, ints({1}, {1}), ints({1}, {3}), ints({1}, {1})})) == (hir::Dims{S("N"), 2}));
  CHECK(e.dims(e.add_node("Pad", {a, ints({4}, {1, 0, 0, 0})})) == (hir::Dims{S("N") + 1, 4}));
  CHECK(e.dims(e.add_node("Pad", {a, ints({4}, {0, 0, 0, 1})})) == (hir::Dims{S("N"), 5}));

  // transpose, squeeze and unsqueeze
  CHECK(e.dims(e.add_node("Transpose", {a}, {hir::Attribute::Ints("perm", {1, 0})})) == (hir::Dims{4, S("N")}));
  int n1 = e.add_symbolic_input("n1", f32, hir::Dims{S("N"), 1});
  CHECK_ERR(e.add_node("Squeeze", {n1, ints({1}, {0})}), "cannot squeeze axis 0");
  CHECK(e.dims(e.add_node("Squeeze", {n1, ints({1}, {1})})) == (hir::Dims{S("N")}));
  CHECK(e.dims(e.add_node("Unsqueeze", {a, ints({1}, {1})})) == (hir::Dims{S("N"), 1, 4}));

  // expand: the symbol broadcasts against 1 only
  CHECK_ERR(e.add_node("Expand", {n1, ints({2}, {5, 3})}), "cannot be broadcast");
  CHECK(e.dims(e.add_node("Expand", {n1, ints({2}, {1, 3})})) == (hir::Dims{S("N"), 3}));

  // conv and pooling: the batch axis passes through; the channel and spatial axes must be integers
  int x = e.add_symbolic_input("x", f32, hir::Dims{S("N"), 3, 8, 8});
  int w = e.add_initializer("", arr(f32, {4, 3, 3, 3}, zeros(108)));
  CHECK(e.dims(e.add_node("Conv", {x, w})) == (hir::Dims{S("N"), 4, 6, 6}));
  int xc = e.add_symbolic_input("xc", f32, hir::Dims{2, S("N"), 8, 8});
  CHECK_ERR(e.add_node("Conv", {xc, w}), "symbolic dimension N at axis 1");
  int xp = e.add_symbolic_input("xp", f32, hir::Dims{S("N"), 2, 4, 4});
  CHECK(e.dims(e.add_node("MaxPool", {xp}, {hir::Attribute::Ints("kernel_shape", {2, 2}), hir::Attribute::Ints("strides", {2, 2})})) == (hir::Dims{S("N"), 2, 2, 2}));

  // layer normalization: the scale has the normalized shape, which holds N when the normalization includes the batch axis
  CHECK(e.dims(e.add_node("LayerNormalization", {a, e.add_initializer("", arr(f32, {4}, zeros(4)))})) == (hir::Dims{S("N"), 4}));
  CHECK_ERR(e.add_node("LayerNormalization", {a, e.add_initializer("", arr(f32, {4}, zeros(4))), -1}, {hir::Attribute::Int("axis", 0)}), "Scale must have the normalized shape");
}

// Products and sums of symbols are exact polynomials (onnxsim's SymExpr): a reshape that folds N*4 into one dimension, a pad and a
// concatenation along the symbol. The values are checked at two batch sizes against the numbers worked out by hand.
static void products() {
  // equality is equality of the polynomials: 4*N is 2*N + 2*N and not 4*N + 1
  CHECK(S("N") * 4 == S("N") * 2 + S("N") * 2);
  CHECK(S("N") * 4 != S("N") * 4 + 1);
  CHECK(S("N") * 4 != S("M") * 4);

  hir::Graph g;
  int x = g.add_symbolic_input("x", f32, hir::Dims{S("N"), 2, 2});
  int minus1 = g.add_initializer("", arr(i64, {1}, {-1}));
  int flat = g.add_node("Reshape", {x, minus1}, {}, "flat");                  // [N,2,2] -> [N*4]
  int padded = g.add_node("Pad", {x, g.add_initializer("", arr(i64, {6}, {1, 0, 0, 0, 0, 0}))}, {}, "padded");   // [N+1,2,2]
  int joined = g.add_node("Concat", {x, x}, {hir::Attribute::Int("axis", 0)}, "joined");                          // [2*N,2,2]
  int flat_pad = g.add_node("Reshape", {padded, minus1}, {}, "flat_pad");     // [(N+1)*4] = [N*4 + 4]
  int halves = g.add_node("Reshape", {flat_pad, g.add_initializer("", arr(i64, {2}, {2, -1}))}, {}, "halves");   // [2, 2*N+2]
  CHECK(g.dims(flat) == (hir::Dims{S("N") * 4}) && g.symbolic(flat));
  CHECK(g.dims(padded) == (hir::Dims{S("N") + 1, 2, 2}) && g.dims(joined) == (hir::Dims{S("N") * 2, 2, 2}));
  CHECK(g.dims(flat_pad) == (hir::Dims{S("N") * 4 + 4}) && g.dims(halves) == (hir::Dims{2, S("N") * 2 + 2}));
  CHECK_ERR(g.add_node("Reshape", {flat_pad, g.add_initializer("", arr(i64, {2}, {-1, 3}))}), "cannot reshape");   // 4N+4 is no multiple of 3
  // an input's dimension is an integer or a symbol, never a polynomial
  CHECK_ERR(g.add_symbolic_input("p", f32, hir::Dims{S("N") * 2}), "an input's dimension is an integer or a symbol");

  // the values at N = 2 and N = 3 (the feed for N = 3 is the rows of batch_input(3), the zero row last)
  hir::Evaluator ev(g);
  const V flat2 = {1, 2, 3, 4, 5, 6, 7, 8}, flat3 = {1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0};
  const V pad2 = {0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8}, pad3 = {0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0};
  const V join2 = {1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8};
  const V join3 = {1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0};
  std::map<std::string, Array> feeds2 = {{"x", batch_input(2)}}, feeds3 = {{"x", batch_input(3)}};
  std::vector<Array> r2 = ev.eval({{"N", 2}}, {flat, padded, joined, flat_pad, halves}, feeds2);
  CHECK(r2.size() == 5 && r2[0].shape == (Shape{8}) && vals(r2[0]) == flat2);
  CHECK(r2[2].shape == (Shape{4, 2, 2}) && vals(r2[2]) == join2);
  CHECK(r2[3].shape == (Shape{12}) && vals(r2[3]) == pad2);
  CHECK(r2[4].shape == (Shape{2, 6}) && vals(r2[4]) == pad2);
  // flat_pad as [4N+4] and padded as [N+1,2,2] are the same numbers
  CHECK(vals(r2[1]) == pad2);
  std::vector<Array> r3 = ev.eval({{"N", 3}}, {flat, padded, joined, flat_pad, halves}, feeds3);
  CHECK(r3.size() == 5 && r3[0].shape == (Shape{12}) && vals(r3[0]) == flat3);
  CHECK(r3[2].shape == (Shape{6, 2, 2}) && vals(r3[2]) == join3);
  CHECK(r3[3].shape == (Shape{16}) && vals(r3[3]) == pad3);
  CHECK(r3[4].shape == (Shape{2, 8}) && vals(r3[4]) == pad3);
  CHECK(ev.bindings_lowered() == 2);

  // bound: the sizes are integers from the start, and the same as the evaluation
  hir::Graph b = g.bind({{"N", 2}});
  CHECK(b.dims(flat) == (hir::Dims{8}) && b.dims(flat_pad) == (hir::Dims{12}) && b.dims(halves) == (hir::Dims{2, 6}) && !b.symbolic(halves));

  // a reshape to N*4 is an output too: it is written as dim_param "poly0" with "4*N" in metadata_props; the reader infers it from the input N
  // again, so the polynomial comes back as itself and binds by N
  std::string bytes = g.to_onnx({flat});
  std::vector<int> outs;
  hir::Graph back = hir::Graph::from_onnx(bytes, &outs);
  CHECK(back.dims(outs[0]) == (hir::Dims{S("N") * 4}));
  CHECK(back.bind({{"N", 2}}).dims(outs[0]) == (hir::Dims{8}));
}

// The exporter and the reader on a graph that has symbols where the operators keep them (no value is computed here).
static void export_symbols() {
  hir::Graph g;
  int x = g.add_symbolic_input("x", f32, hir::Dims{S("N"), 3});
  int y = g.add_node("Neg", {x});
  std::string bytes = g.to_onnx({y});
  CHECK(bytes.find(std::string("\x12\x01N", 3)) != std::string::npos);
  std::vector<int> outs;
  hir::Graph back = hir::Graph::from_onnx(bytes, &outs);
  CHECK(back.dims(outs[0]) == (hir::Dims{S("N"), 3}));
  // a symbol and an integer are different dimensions: a model with [N, 3] where the graph has [2, 3] is a name collision
  hir::Graph other;
  other.add_symbolic_input("x", f32, hir::Dims{2, 3});
  CHECK_ERR(other.merge_onnx(bytes), "name collision");
}

int main(int argc, char** argv) {
  std::string dir = argc > 1 ? argv[1] : "";
  symbolic_mlp(dir);
  shape_inference();
  products();
  export_symbols();
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
