// The ONNX Runtime back end (lib/uop/nfcuop_ort.hpp): hir graphs exported with to_onnx and run by onnxruntime, loaded with dlopen
// from $NFCUOP_ORT_LIB (or the common names), compared with the interpreter (hir::Evaluator). Float results must agree to a
// relative 1e-5 (an absolute 1e-6 near zero; NaN with NaN); integer and bool results exactly; shapes and dtypes exactly.
// Covered: a static graph with elementwise ops, reductions, Reshape/Transpose, Gemm/MatMul, integer Div/Mod, Greater/Where,
// a scalar output, an input as an output; a symbolic batch run unbound and bound (Graph::bind) at two sizes; the numpy API with
// np.backend = Ort; the errors (a missing library, a missing feed, a wrong shape, a symbol with two sizes).
// When the library cannot be loaded the test prints one line starting with SKIP and exits 0.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"
#include "nfcuop_np.hpp"
#include "nfcuop_ort.hpp"

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
static const DType f32 = DType::Float32, i64 = DType::Int64, i32 = DType::Int32;
static hir::Dim S(const std::string& s) { return hir::Dim::symbol(s); }
static Array arr(DType d, const Shape& s, const V& v) { return Array::from_doubles(d, s, v); }
static V vals(const Array& a) { V v; for (const Scalar& s : a.data) v.push_back(s.as_double()); return v; }

// "" when `got` agrees with `want` under the rules of the header comment, else the reason.
static std::string differs(const std::string& label, const Array& got, const Array& want) {
  if (got.dtype != want.dtype) return label + ": dtype " + name(got.dtype) + " vs " + name(want.dtype);
  if (got.shape != want.shape) return label + ": shape " + to_string(got.shape) + " vs " + to_string(want.shape);
  for (size_t k = 0; k < got.data.size(); k++) {
    const Scalar& a = got.data[k];
    const Scalar& b = want.data[k];
    if (is_float(got.dtype)) {
      if (std::isnan(a.f) || std::isnan(b.f)) {
        if (std::isnan(a.f) != std::isnan(b.f)) return label + ": element " + std::to_string(k) + " is NaN on one side only";
        continue;
      }
      if (!(std::fabs(a.f - b.f) <= 1e-6 + 1e-5 * std::fabs(b.f)))
        return label + ": element " + std::to_string(k) + " is " + std::to_string(a.f) + ", the interpreter " + std::to_string(b.f);
    } else if (a.i != b.i) {
      return label + ": element " + std::to_string(k) + " is " + std::to_string(a.i) + ", the interpreter " + std::to_string(b.i);
    }
  }
  return "";
}

static void expect_same(const std::string& label, const Array& got, const Array& want) {
  checks++;
  std::string why = differs(label, got, want);
  if (!why.empty()) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, why.c_str()); }
}

// The interpreter's values of `outs` for the feeds (and the bindings of the symbols).
static std::vector<Array> interp(const hir::Graph& g, const std::vector<int>& outs, const std::map<std::string, Array>& feeds, const hir::Bindings& b = {}) {
  hir::Evaluator ev(g);
  return ev.eval(b, outs, feeds);
}

// Static graph. x [2,3] and xi [2,3] (int64) are fed; w [4,3], c [4] are initializers.
static hir::Graph forward_graph(std::vector<int>* outs) {
  hir::Graph g;
  int x = g.add_input("x", f32, {2, 3});
  int xi = g.add_input("xi", i64, {2, 3});
  int w = g.add_initializer("w", arr(f32, {4, 3}, {1, 0.5, -1, 0, 2, 0.25, -0.75, 1, 1.5, 0.5, -2, 3}));
  int c = g.add_initializer("c", arr(f32, {4}, {0.5, -1, 2, 0.25}));
  // Gemm: 1.5 * x * w^T + 0.5 * c, [2,4]
  int gemm = g.add_node("Gemm", {x, w, c}, {hir::Attribute::Float("alpha", 1.5), hir::Attribute::Float("beta", 0.5), hir::Attribute::Int("transB", 1)});
  // elementwise: relu(h) + (h*h - tanh(h))
  int sq = g.add_node("Mul", {gemm, gemm});
  int th = g.add_node("Tanh", {gemm});
  int rl = g.add_node("Relu", {gemm});
  int df = g.add_node("Sub", {sq, th});
  int e = g.add_node("Add", {rl, df}, {}, "elementwise");
  // reductions: sum over axis 1 (no keepdims) and max over axis 0 (keepdims)
  int ax1 = g.add_initializer("axes1", arr(i64, {1}, {1}));
  int sum = g.add_node("ReduceSum", {e, ax1}, {hir::Attribute::Int("keepdims", 0)}, "sum");
  int ax0 = g.add_initializer("axes0", arr(i64, {1}, {0}));
  int mx = g.add_node("ReduceMax", {e, ax0}, {hir::Attribute::Int("keepdims", 1)}, "max");
  // Transpose then Reshape back to [2,4] (a different element order)
  int tr = g.add_node("Transpose", {e}, {hir::Attribute::Ints("perm", {1, 0})});
  int shp = g.add_initializer("shape", arr(i64, {2}, {2, 4}));
  int rs = g.add_node("Reshape", {tr, shp}, {}, "reshaped");
  // MatMul [2,4] x [4,3]
  int mm = g.add_node("MatMul", {e, w}, {}, "matmul");
  // integers: xi / 3 (truncating) + xi % 3 (the sign of xi), then the sum of all of them (a scalar)
  int k3 = g.add_initializer("three", arr(i64, {2, 3}, {3, 3, 3, 3, 3, 3}));
  int q = g.add_node("Div", {xi, k3});
  int r = g.add_node("Mod", {xi, k3}, {hir::Attribute::Int("fmod", 1)});
  int qr = g.add_node("Add", {q, r}, {}, "int_pair");
  int axall = g.add_initializer("axes_all", arr(i64, {2}, {0, 1}));
  int isum = g.add_node("ReduceSum", {qr, axall}, {hir::Attribute::Int("keepdims", 0)}, "int_total");
  // Greater and Where: |x| on the floats, and the mask itself
  int zero = g.add_initializer("zero", arr(f32, {}, {0}));
  int pos = g.add_node("Greater", {x, zero}, {}, "positive");
  int neg = g.add_node("Neg", {x});
  int wh = g.add_node("Where", {pos, x, neg}, {}, "abs");
  *outs = {e, sum, mx, rs, mm, qr, isum, wh, pos, x};
  return g;
}

static std::map<std::string, Array> forward_feeds() {
  return {{"x", arr(f32, {2, 3}, {1.5, -2, 0.25, 3, -0.5, 4})}, {"xi", arr(i64, {2, 3}, {7, -7, 5, -5, 9, -2})}};
}

static void forward() {
  std::vector<int> outs;
  hir::Graph g = forward_graph(&outs);
  std::map<std::string, Array> feeds = forward_feeds();
  std::vector<Array> want = interp(g, outs, feeds);
  std::vector<Array> got = ort::run(g, outs, feeds);
  CHECK(got.size() == outs.size() && want.size() == outs.size());
  if (got.size() != outs.size() || want.size() != outs.size()) return;
  const char* names[] = {"elementwise", "sum", "max", "reshaped", "matmul", "int_pair", "int_total", "abs", "positive", "x (an input)"};
  for (size_t k = 0; k < outs.size(); k++) expect_same(std::string("forward/") + names[k], got[k], want[k]);
  // the integer results by hand: 7/3 = 2, -7/3 = -2, 5/3 = 1, -5/3 = -1, 9/3 = 3, -2/3 = 0; the remainders 1 -1 2 -2 0 -2 (the
  // sign of the dividend); the pair sums 3 -3 3 -3 3 -2, whose total is 1
  CHECK(vals(got[5]) == (V{3, -3, 3, -3, 3, -2}));
  CHECK(got[6].shape.empty() && vals(got[6]) == V{1});
  CHECK(got[9].shape == (Shape{2, 3}) && vals(got[9]) == vals(feeds.at("x")));
}

// Dynamic batch: x [N, 3] (ONNX dim_param N) -> MatMul w [3,2] -> Add b -> Softmax -> probs [N,2]; colsum = ReduceSum over the batch [3].
static hir::Graph batch_graph(std::vector<int>* outs) {
  hir::Graph g;
  int x = g.add_symbolic_input("x", f32, hir::Dims{S("N"), 3});
  int w = g.add_initializer("w", arr(f32, {3, 2}, {1, -1, 0.5, 2, -2, 0.25}));
  int b = g.add_initializer("b", arr(f32, {2}, {0.1, -0.2}));
  int h = g.add_node("MatMul", {x, w});
  int hb = g.add_node("Add", {h, b});
  int p = g.add_node("Softmax", {hb}, {hir::Attribute::Int("axis", -1)}, "probs");
  int ax0 = g.add_initializer("axes0", arr(i64, {1}, {0}));
  int cs = g.add_node("ReduceSum", {x, ax0}, {hir::Attribute::Int("keepdims", 0)}, "colsum");
  *outs = {p, cs};
  return g;
}

static std::map<std::string, Array> batch_feeds(int n) {
  V v;
  for (int k = 0; k < n * 3; k++) v.push_back(0.5 * k - 1.0);
  return {{"x", arr(f32, {n, 3}, v)}};
}

static void symbolic_batch() {
  std::vector<int> outs;
  hir::Graph g = batch_graph(&outs);
  for (int n : {2, 5}) {
    std::map<std::string, Array> feeds = batch_feeds(n);
    std::vector<Array> want = interp(g, outs, feeds, {{"N", n}});
    std::vector<Array> got = ort::run(g, outs, feeds);
    std::string tag = "batch N=" + std::to_string(n);
    if (got.size() != 2 || want.size() != 2) { CHECK(false); continue; }
    expect_same(tag + "/probs", got[0], want[0]);
    expect_same(tag + "/colsum", got[1], want[1]);
    CHECK(got[0].shape == (Shape{n, 2}) && got[1].shape == (Shape{3}));
    // the bound graph (Graph::bind: every operator inferred again with the sizes) is a static model
    hir::Graph bound = g.bind({{"N", n}});
    std::vector<Array> got_b = ort::run(bound, outs, feeds);
    if (got_b.size() == 2) {
      expect_same(tag + " bound/probs", got_b[0], want[0]);
      expect_same(tag + " bound/colsum", got_b[1], want[1]);
    } else {
      CHECK(false);
    }
  }
}

// The numpy API with np.backend = Ort (eval and eval_all), against the same session on the interpreter.
static void numpy_selection() {
  nfcuop::np::Session np;
  auto x = np.placeholder("x", {2, 3});
  auto w = np.array({1, 0, 0, 1, 1, 1}, {3, 2});
  auto y = softmax(matmul(x, w) + np.array({0.5, -0.5}));
  auto z = matmul(x, w) * 2 - 1;
  std::map<std::string, Array> feeds = {{"x", arr(f32, {2, 3}, {0.25, -1, 2, 3, 0.5, -4})}};
  np.backend = ut::Session::Backend::Interpreter;
  Array want = np.eval(y, feeds);
  np.backend = ut::Session::Backend::Ort;
  expect_same("np eval (ort)", np.eval(y, feeds), want);
  std::vector<Array> both = np.eval_all({y, z}, feeds);
  np.backend = ut::Session::Backend::Interpreter;
  std::vector<Array> both_want = np.eval_all({y, z}, feeds);
  CHECK(both.size() == 2 && both_want.size() == 2);
  if (both.size() == 2 && both_want.size() == 2) {
    expect_same("np eval_all[0] (ort)", both[0], both_want[0]);
    expect_same("np eval_all[1] (ort)", both[1], both_want[1]);
  }
  // a placeholder is its own value: no model is run for it
  np.backend = ut::Session::Backend::Ort;
  expect_same("np eval placeholder (ort)", np.eval(x, feeds), feeds.at("x"));
  // the UOp-level session has no graph: it refuses the back end instead of rendering C for it
  ut::Session s;
  s.backend = ut::Session::Backend::Ort;
  CHECK_ERR(s.eval(s.placeholder("p", {2}), {{"p", arr(f32, {2}, {1, 2})}}), "evaluate through np::Session");
}

// Errors: a feed that is missing, of the wrong shape, or a symbol with two sizes.
static void errors() {
  std::vector<int> outs;
  hir::Graph g = forward_graph(&outs);
  std::map<std::string, Array> feeds = forward_feeds();
  CHECK_ERR(ort::run(g, {outs[4]}, {}), "no feed for input x");
  std::map<std::string, Array> wrong = feeds;
  wrong["x"] = arr(f32, {3, 2}, {1, 2, 3, 4, 5, 6});
  CHECK_ERR(ort::run(g, {outs[0]}, wrong), "has shape");
  hir::Graph two;
  int a = two.add_symbolic_input("a", f32, hir::Dims{S("N"), 3});
  int b = two.add_symbolic_input("b", f32, hir::Dims{S("N"), 3});
  int s = two.add_node("Add", {a, b});
  CHECK_ERR(ort::run(two, {s}, {{"a", arr(f32, {2, 3}, V(6, 1.0))}, {"b", arr(f32, {3, 3}, V(9, 1.0))}}), "symbol N");
}

int main() {
  // A missing library is an Error that names the variable. Nothing is cached on a failed load, so the next call retries.
  hir::Graph g0;
  int x0 = g0.add_input("x", f32, {2});
  int y0 = g0.add_node("Neg", {x0});
  const char* old = std::getenv("NFCUOP_ORT_LIB");
  std::string saved = old ? old : "";
  bool had = old != nullptr;
  setenv("NFCUOP_ORT_LIB", "/nonexistent/nfcuop-ort/libonnxruntime.so", 1);
  CHECK_ERR(ort::run(g0, {y0}, {{"x", arr(f32, {2}, {1, 2})}}), "NFCUOP_ORT_LIB");
  if (had) setenv("NFCUOP_ORT_LIB", saved.c_str(), 1);
  else unsetenv("NFCUOP_ORT_LIB");

  std::string why;
  if (!ort::available(&why)) {
    std::printf("SKIP test_ort: %s\n", why.c_str());
    return 0;
  }
  forward();
  symbolic_batch();
  numpy_selection();
  errors();
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
