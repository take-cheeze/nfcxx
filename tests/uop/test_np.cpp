// The numpy-like API (nfcuop_np.hpp) over the ONNX-style graph: values, errors, slicing and concatenation, the graph, the
// ONNX export (written to the directory given as argv[1], when there is one, for tests/uop/onnx_check.py).
#include <cmath>
#include <cstdio>
#include <fstream>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_np.hpp"

using namespace nfcuop;
using namespace nfcuop::np;

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

using V = std::vector<double>;
static bool near(const V& a, const V& b, double tol = 1e-5) {
  if (a.size() != b.size()) return false;
  for (size_t k = 0; k < a.size(); k++)
    if (!(std::fabs(a[k] - b[k]) <= tol * (1 + std::fabs(b[k])))) return false;
  return true;
}
#define CHECK_VALS(t, ...) do { V want_ = __VA_ARGS__; V got_ = (t).tolist(); CHECK(near(got_, want_)); \
    if (!near(got_, want_)) { std::printf("  got:"); for (double d : got_) std::printf(" %g", d); std::printf("\n"); } } while (0)

static void numpy_api() {
  Session np;
  const DType i32 = DType::Int32, i64 = DType::Int64, f32 = DType::Float32, f64 = DType::Float64;
  Tensor a = np.array({1, 2, 3, 4, 5, 6}, {2, 3});
  CHECK(a.shape() == (Shape{2, 3}) && a.ndim() == 2 && a.size() == 6 && a.dtype() == f32);
  CHECK(a.str() == "[[1., 2., 3.], [4., 5., 6.]]");
  CHECK(np.array2d({{1, 2}, {3, 4}}).str() == "[[1., 2.], [3., 4.]]");
  CHECK(np.array({1, 2, 3}, i32).str() == "[1, 2, 3]");
  CHECK(np.array({1, 0}, DType::Bool).str() == "[True, False]");
  CHECK(np.scalar(2.5).str() == "2.5" && np.scalar(2.5).ndim() == 0);
  CHECK(np.scalar(2.5).item() == 2.5);
  CHECK_THROWS(a.item());
  CHECK_THROWS(np.array({1, 2, 3}, {2, 2}));
  CHECK(np.arange(4).str() == "[0, 1, 2, 3]" && np.arange(4).dtype() == i32);
  CHECK(np.arange(1.0, 2.0, 0.25).str() == "[1., 1.25, 1.5, 1.75]");
  CHECK(np.arange(5, i32).str() == "[0, 1, 2, 3, 4]");
  CHECK(np.linspace(0, 1, 5).str() == "[0., 0.25, 0.5, 0.75, 1.]");
  CHECK(np.eye(2).str() == "[[1., 0.], [0., 1.]]");
  CHECK(np.zeros({2, 2}).str() == "[[0., 0.], [0., 0.]]" && np.ones({2}, i32).str() == "[1, 1]");
  CHECK(np.full({2}, 7, i32).str() == "[7, 7]");

  // shape manipulation
  CHECK(a.T().str() == "[[1., 4.], [2., 5.], [3., 6.]]");
  CHECK(a.reshape({3, 2}).str() == "[[1., 2.], [3., 4.], [5., 6.]]");
  CHECK(a.reshape({-1}).shape() == (Shape{6}) && a.reshape({3, -1}).shape() == (Shape{3, 2}));
  CHECK_THROWS(a.reshape({4, -1}));
  CHECK_THROWS(a.reshape({-1, -1}));
  CHECK(a.flatten().shape() == (Shape{6}));
  CHECK(a.expand_dims(0).shape() == (Shape{1, 2, 3}) && a.expand_dims(-1).shape() == (Shape{2, 3, 1}));
  CHECK(a.expand_dims(1).squeeze().shape() == (Shape{2, 3}) && a.expand_dims(1).squeeze(1).shape() == (Shape{2, 3}));
  CHECK_THROWS(a.squeeze(0));
  CHECK(a.broadcast_to({4, 2, 3}).shape() == (Shape{4, 2, 3}));
  CHECK_THROWS(a.broadcast_to({3}));
  CHECK(a.swapaxes(0, 1).str() == a.T().str());
  CHECK(np.arange(24).reshape({2, 3, 4}).transpose({2, 0, 1}).shape() == (Shape{4, 2, 3}));
  CHECK(np.arange(24).reshape({2, 3, 4}).transpose({2, 0, 1}).tolist()[1] == 4);  // element (0,0,1) of the result is source (0,1,0)

  // reductions
  CHECK(a.sum().item() == 21 && a.sum().ndim() == 0);
  CHECK(a.sum(0).str() == "[5., 7., 9.]" && a.sum(1).str() == "[6., 15.]" && a.sum(-1).str() == "[6., 15.]");
  CHECK(a.sum(1, true).shape() == (Shape{2, 1}));
  CHECK(a.sum({0, 1}).item() == 21);
  CHECK(a.mean().item() == 3.5 && a.mean(0).str() == "[2.5, 3.5, 4.5]");
  CHECK(a.max().item() == 6 && a.min().item() == 1 && a.max(1).str() == "[3., 6.]" && a.min(0).str() == "[1., 2., 3.]");
  CHECK(np.array({-5, 3, -2}, i32).min().item() == -5);
  CHECK(np.array({-2147483648.0, 3, 5}, i32).min().item() == -2147483648.0);   // the complement trick cannot overflow
  CHECK(np.array({1, 0, 1}, DType::Bool).sum().item() == 2);
  CHECK(np.array({1, 2, 3, 4}, i32).mean().item() == 2.5);
  CHECK(std::fabs(a.var().item() - 35.0 / 12.0) < 1e-6 && std::fabs(a.stddev().item() - std::sqrt(35.0 / 12.0)) < 1e-6);
  CHECK(near(a.var(Axes{1}).tolist(), {2.0 / 3.0, 2.0 / 3.0}));
  CHECK_THROWS(a.sum(2));
  CHECK_THROWS(a.sum({0, 0}));

  // broadcasting and promotion
  Tensor b = np.arange(3);
  CHECK((a + b).str() == "[[1., 3., 5.], [4., 6., 8.]]");
  CHECK((a * 2).str() == "[[2., 4., 6.], [8., 10., 12.]]" && (2 * a).str() == (a * 2).str());
  CHECK((a - 1.5).tolist()[0] == -0.5 && (10 - a).tolist()[0] == 9);
  CHECK((a / 2).tolist()[1] == 1 && (12 / a).tolist()[2] == 4);
  CHECK((a + np.arange(2).reshape({2, 1})).str() == "[[1., 2., 3.], [5., 6., 7.]]");
  CHECK((np.arange(3).reshape({3, 1}) + np.arange(2)).shape() == (Shape{3, 2}));
  CHECK_THROWS(a + np.arange(4));
  Tensor ia = np.array({1, 2, 3}, i32);
  CHECK((ia + 1).dtype() == i32 && (ia + 1.5).dtype() == f32 && (ia / 2).dtype() == f32 && (ia / 2).str() == "[0.5, 1., 1.5]");
  CHECK((ia + np.array({1, 2, 3}, i64)).dtype() == i64);
  CHECK((ia + np.array({1, 2, 3}, f64)).dtype() == f64);
  CHECK((np.array({1, 2}, DType::Bool) + 1).dtype() == i32);
  CHECK((np.array({1.5}, f64) * 0.1).dtype() == f64 && (np.array({1.5}, f64) * 0.1).item() == 1.5 * 0.1);  // exact scalar for float64
  CHECK((-ia).str() == "[-1, -2, -3]");
  CHECK((ia * ia).str() == "[1, 4, 9]" && ia.square().str() == "[1, 4, 9]");

  // comparisons, logic, where
  CHECK((a > 3).str() == "[[False, False, False], [True, True, True]]");
  CHECK((a <= 3).str() == "[[True, True, True], [False, False, False]]");
  CHECK((a >= 4).sum().item() == 3 && (a == 4).sum().item() == 1 && (a != 4).sum().item() == 5);
  CHECK(((a > 1) & (a < 4)).sum().item() == 2 && ((a < 2) | (a > 5)).sum().item() == 2 && ((a > 1) ^ (a > 2)).sum().item() == 1);
  CHECK(logical_not(a > 3).sum().item() == 3 && logical_not(ia - 1).str() == "[True, False, False]");
  CHECK(where(a > 3, a, 0 * a).str() == "[[0., 0., 0.], [4., 5., 6.]]");
  CHECK(where(a > 3, a, np.scalar(-1)).tolist()[0] == -1);
  CHECK(where(ia, np.scalar(1, i32), np.scalar(2, i32)).str() == "[1, 1, 1]" && where(ia - 1, np.scalar(1, i32), np.scalar(2, i32)).str() == "[2, 1, 1]");
  CHECK(maximum(a, np.scalar(3)).str() == "[[3., 3., 3.], [4., 5., 6.]]" && minimum(a, np.scalar(3)).str() == "[[1., 2., 3.], [3., 3., 3.]]");
  CHECK(a.clip(2, 5).str() == "[[2., 2., 3.], [4., 5., 5.]]");
  CHECK((a - 3).relu().str() == "[[0., 0., 0.], [1., 2., 3.]]" && relu(a - 3).sum().item() == 6);
  CHECK((a - 3).abs().sum().item() == 2 + 1 + 0 + 1 + 2 + 3);

  // floor semantics
  Tensor n = np.array({-7, 7, -7, 7}, i32), d = np.array({2, -2, -2, 2}, i32);
  CHECK(floor_divide(n, d).str() == "[-4, -4, 3, 3]");
  CHECK((n % d).str() == "[1, -1, -1, 1]");
  CHECK((n % 3).str() == "[2, 1, 2, 1]");
  CHECK_THROWS(a % 2);
  CHECK_THROWS(floor_divide(a, a));

  // math
  Tensor x = np.array({-2, -0.5, 0, 0.5, 2});
  V xs{-2, -0.5, 0, 0.5, 2};
  auto fn = [&](double (*f)(double)) { V v; for (double q : xs) v.push_back(f(q)); return v; };
  CHECK(near(x.exp().tolist(), fn(std::exp), 1e-5));
  CHECK(near(x.sin().tolist(), fn(std::sin), 1e-5) && near(x.cos().tolist(), fn(std::cos), 1e-5));
  CHECK(near(x.tanh().tolist(), fn(std::tanh), 1e-5) && near(tanh(x * 100).tolist(), V{-1, -1, 0, 1, 1}));
  CHECK(near(x.sigmoid().tolist(), V{1 / (1 + std::exp(2.0)), 1 / (1 + std::exp(0.5)), 0.5, 1 / (1 + std::exp(-0.5)), 1 / (1 + std::exp(-2.0))}));
  CHECK(near(x.abs().sqrt().tolist(), V{std::sqrt(2.0), std::sqrt(0.5), 0, std::sqrt(0.5), std::sqrt(2.0)}));
  CHECK(near(log(x.abs() + 1).tolist(), V{std::log(3.0), std::log(1.5), 0, std::log(1.5), std::log(3.0)}));
  V rc = x.reciprocal().tolist();
  CHECK(near(V{rc[0], rc[4]}, V{-0.5, 0.5}) && std::isinf(rc[2]));
  CHECK(sqrt(np.array({4, 9}, i32)).str() == "[2., 3.]");
  Tensor logits = np.array2d({{1, 2, 3}, {1, 1, 1}});
  Tensor sm = logits.softmax();
  CHECK(near(sm.sum(1).tolist(), {1, 1}) && near(sm.tolist(), {0.0900306, 0.2447285, 0.6652410, 1.0 / 3, 1.0 / 3, 1.0 / 3}, 1e-5));
  CHECK(near(logits.log_softmax().exp().tolist(), sm.tolist(), 1e-5));
  CHECK(near(logits.softmax(0).sum(0).tolist(), {1, 1, 1}));

  // matmul
  CHECK(matmul(a, a.T()).str() == "[[14., 32.], [32., 77.]]");
  CHECK(matmul(a, np.eye(3)).str() == a.str());
  CHECK(matmul(a, np.array({1, 1, 1})).str() == "[6., 15.]");
  CHECK(matmul(np.array({1, 1}), a).str() == "[5., 7., 9.]");
  CHECK(matmul(np.array({1, 2, 3}), np.array({4, 5, 6})).item() == 32 && matmul(np.array({1, 2, 3}), np.array({4, 5, 6})).ndim() == 0);
  CHECK(dot(a, a.T()).str() == matmul(a, a.T()).str());
  Tensor ba = np.arange(24).reshape({2, 3, 4}), bb = np.arange(8).reshape({4, 2});   // batch against a plain matrix
  Tensor bm = matmul(ba, bb);
  CHECK(bm.shape() == (Shape{2, 3, 2}));
  CHECK(bm.tolist()[0] == 0 * 0 + 1 * 2 + 2 * 4 + 3 * 6 && bm.tolist()[11] == 20 * 1 + 21 * 3 + 22 * 5 + 23 * 7);
  CHECK(matmul(ba, ba.transpose({0, 2, 1})).shape() == (Shape{2, 3, 3}));
  CHECK_THROWS(matmul(a, a));
  CHECK(matmul(np.array({1, 2}, i32), np.array({3, 4}, i32)).dtype() == i32);
  CHECK(matmul(np.array({1, 2}, i32), np.array({3, 4}, i32)).item() == 11);

  // laziness, placeholders, optimization on and off
  size_t before = np.graph().num_values();
  Tensor lazy = (a * 2 + 1).sum();
  CHECK(np.graph().num_values() > before);
  Tensor ph = np.placeholder("input", {2, 3});
  Tensor f = (ph * ph).sum(1);
  Array fed = Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6});
  CHECK(np.eval(f, {{"input", fed}}).data[1] == Scalar::from_double(f32, 77));
  CHECK_THROWS(np.eval(f));
  CHECK_THROWS(np.eval(f, {{"input", Array::from_doubles(f32, {3, 2}, {1, 2, 3, 4, 5, 6})}}));
  CHECK_THROWS(np.placeholder("_bufX", {1}));
  np.optimize = false;
  double raw = lazy.item();
  np.optimize = true;
  CHECK(raw == lazy.item() && raw == 2 * 21 + 6);
  // x + 0 and x * 1 vanish from the graph that is evaluated
  Tensor plain = (a + 0) * 1;
  CHECK(graph_rewrite(np.uop_session().graph(), symbolic(), np.lower(plain).uop()) == np.lower(a).uop());
  Session other;
  CHECK_THROWS(a + other.scalar(1));
  CHECK_THROWS(Tensor().numpy());
  CHECK(!a.dump().empty());
}


static void default_dtypes() {
  const DType i32 = DType::Int32, i64 = DType::Int64, f32 = DType::Float32, f64 = DType::Float64;
  {  // the 32-bit defaults
    Session np;
    CHECK(np.default_float == f32 && np.default_int == i32);
    CHECK(np.array({1, 2}).dtype() == f32 && np.scalar(1).dtype() == f32 && np.zeros({2}).dtype() == f32 && np.ones({2}).dtype() == f32);
    CHECK(np.linspace(0, 1, 3).dtype() == f32 && np.eye(2).dtype() == f32 && np.placeholder("p", {2}).dtype() == f32);
    CHECK(np.arange(3).dtype() == i32 && np.arange(0, 6, 2).dtype() == i32 && np.arange(0.5, 2.0, 0.5).dtype() == f32 && np.arange(0, 6, 2.0).dtype() == f32);
    CHECK(np.full({2}, 7).dtype() == i32 && np.full({2}, 7.5).dtype() == f32 && np.full({2}, 7, f64).dtype() == f64);
    Tensor ia = np.array({1, 2, 3, 4}, i32), bo = np.array({1, 0, 1, 1}, DType::Bool);
    CHECK((ia / 2).dtype() == f32 && ia.mean().dtype() == f32 && ia.exp().dtype() == f32 && ia.softmax().dtype() == f32);
    CHECK(bo.sum().dtype() == i32 && ia.sum().dtype() == i32 && (bo + bo).dtype() == i32 && (bo + 1).dtype() == i32 && matmul(bo, bo).dtype() == i32);
    CHECK((ia + 0.5).dtype() == f32 && (ia + 1).dtype() == i32 && (np.array({1.5}, f64) + 1).dtype() == f64 && (np.array({1.5}) * 2.5).dtype() == f32);
  }
  {  // numpy's defaults: int64 and float64
    Session np;
    np.default_float = f64;
    np.default_int = i64;
    CHECK(np.array({1, 2}).dtype() == f64 && np.scalar(1).dtype() == f64 && np.zeros({2}).dtype() == f64 && np.eye(2).dtype() == f64);
    CHECK(np.arange(3).dtype() == i64 && np.arange(0, 6, 2).dtype() == i64 && np.arange(0.5, 2.0, 0.5).dtype() == f64 && np.full({2}, 7).dtype() == i64);
    CHECK(np.array({1, 2}, f32).dtype() == f32 && np.arange(3, i32).dtype() == i32 && np.zeros({2}, i32).dtype() == i32);   // an explicit dtype wins
    Tensor ia = np.array({1, 2, 3, 4}, i32), bo = np.array({1, 0, 1, 1}, DType::Bool);
    CHECK((ia / 2).dtype() == f64 && ia.mean().dtype() == f64 && ia.sqrt().dtype() == f64 && ia.clip(1, 3).dtype() == f64);
    CHECK(ia.sum().dtype() == i64 && bo.sum().dtype() == i64 && (bo + bo).dtype() == i64);   // sums widen, as in numpy
    CHECK((ia + 1).dtype() == i32 && (ia + 0.5).dtype() == f64);                               // a Python-style scalar is weak
    Tensor f = np.array({1, 2, 3}, f32);
    CHECK((f * 0.1).dtype() == f32 && (f + 1).dtype() == f32 && f.sum().dtype() == f32);
    CHECK(ia.mean().item() == 2.5 && np.arange(5).sum().item() == 10 && std::fabs((np.array({1, 2, 3}) / 3.0).tolist()[0] - 1.0 / 3) < 1e-15);   // float64 is real
    CHECK(softmax(np.array({1, 2, 3}, i32)).dtype() == f64);
    // the model written for ONNX has the dtypes chosen here
    Tensor x = np.placeholder("x", {2});
    CHECK(x.dtype() == f64 && np.to_onnx({{"y", x * 2}}).size() > 20);
  }
}

static void slicing_and_concat() {
  Session np;
  const DType i32 = DType::Int32, f64 = DType::Float64;
  Tensor m = np.arange(24).reshape({2, 3, 4});
  CHECK(m.slice(2, 1, 3).shape() == (Shape{2, 3, 2}));
  CHECK(m.slice(2, 1, 3).tolist()[0] == 1 && m.slice(2, 1, 3).tolist()[2] == 5);
  CHECK(m.slice(1, 1, None).shape() == (Shape{2, 2, 4}) && m.slice(1, None, 2).shape() == (Shape{2, 2, 4}));
  CHECK(m.slice(2, None, None, 2).str() == m.slice(2, 0, 4, 2).str() && m.slice(2, None, None, 2).shape() == (Shape{2, 3, 2}));
  CHECK(near(m.slice(2, None, None, 2).slice(0, 1, 2).slice(1, 0, 1).tolist(), {12, 14}));
  CHECK(near(m.slice(2, None, None, 3).slice(0, 0, 1).slice(1, 0, 1).tolist(), {0, 3}));
  CHECK(near(m.slice(2, None, None, -1).slice(0, 0, 1).slice(1, 0, 1).tolist(), {3, 2, 1, 0}));
  CHECK(near(m.slice(2, -1, None, -2).slice(0, 0, 1).slice(1, 0, 1).tolist(), {3, 1}));
  CHECK(near(m.slice(2, 3, 0, -1).slice(0, 0, 1).slice(1, 0, 1).tolist(), {3, 2, 1}));
  CHECK(near(m.slice(2, -3, -1).slice(0, 0, 1).slice(1, 0, 1).tolist(), {1, 2}));
  CHECK(m.slice(0, -1, None).shape() == (Shape{1, 3, 4}) && m.slice(0, -1, None).tolist()[0] == 12);
  CHECK(m.slice(-1, 100, None, -1).shape() == (Shape{2, 3, 4}));  // out of range bounds clamp, like Python
  CHECK_THROWS(m.slice(2, 3, 1));        // empty
  CHECK_THROWS(m.slice(2, 5, None));     // empty
  CHECK_THROWS(m.slice(3, 0, 1));        // bad axis
  CHECK_THROWS(m.slice(2, 0, 3, 0));     // step 0
  CHECK(m.at(1).shape() == (Shape{3, 4}) && m.at(1).tolist()[0] == 12 && m.at(-1).tolist()[0] == 12);
  CHECK(m.at(2, 1).shape() == (Shape{2, 4}) && m.at(2, 1).tolist()[1] == 9);
  CHECK(m.at(-1, 2).shape() == (Shape{2, 3}) && m.at(-1, 2).tolist()[0] == 3);
  CHECK_THROWS(m.at(2));
  CHECK_THROWS(m.at(-3));
  CHECK(np.arange(4).flip().str() == "[3, 2, 1, 0]" && m.flip(1).tolist()[0] == 8);
  // a chain of slices and arithmetic
  Tensor row = np.arange(10);
  CHECK((row.slice(0, 1, None) - row.slice(0, None, -1)).sum().item() == 9);  // differences of neighbours
  // concatenate and stack
  Tensor a = np.array({1, 2, 3, 4, 5, 6}, {2, 3}), b = a * 10;
  CHECK(concatenate({a, b}, 0).shape() == (Shape{4, 3}) && concatenate({a, b}, 1).shape() == (Shape{2, 6}));
  CHECK(concatenate({a, b}, 1).str() == "[[1., 2., 3., 10., 20., 30.], [4., 5., 6., 40., 50., 60.]]");
  CHECK(concatenate({a, b, a}, -1).shape() == (Shape{2, 9}));
  CHECK(concatenate({a}, 0).str() == a.str());
  CHECK(concatenate({np.array({1, 2}, i32), np.array({0.5}, f64)}).dtype() == f64);
  CHECK(concatenate({np.array({1, 2}, i32), np.array({3}, i32)}).str() == "[1, 2, 3]");
  CHECK_THROWS(concatenate({a, a.T()}, 0));
  CHECK_THROWS(concatenate({}, 0));
  CHECK_THROWS(concatenate({a, np.arange(3)}, 0));
  CHECK(stack({a, b}).shape() == (Shape{2, 2, 3}) && stack({a, b}, 2).shape() == (Shape{2, 3, 2}) && stack({a, b}, -1).shape() == (Shape{2, 3, 2}));
  CHECK(stack({np.arange(2), np.arange(2) + 5}).str() == "[[0, 1], [5, 6]]");
  CHECK(near(stack({a, b}, 2).tolist(), V{1, 10, 2, 20, 3, 30, 4, 40, 5, 50, 6, 60}));
  CHECK_THROWS(stack({a, a.T()}));
  // -0.0 survives a concatenation (the lowering must not add zeros)
  Tensor nz = np.array({-0.0, 1.0});
  CHECK(std::signbit(concatenate({nz, nz}).numpy().data[0].f));
}

// Evaluates the outputs, exports them, reads the ONNX file back and checks that the export is byte-identical, and that the
// read-back graph, lowered and interpreted, gives the same bits as the numpy-like API did.
static void onnx_round_trip(Session& np, const std::vector<std::pair<std::string, Tensor>>& outs, const std::map<std::string, Array>& feeds) {
  std::string bytes = np.to_onnx(outs);
  std::vector<int> ids;
  hir::Graph g = hir::Graph::from_onnx(bytes, &ids);
  CHECK(ids.size() == outs.size());
  CHECK(g.to_onnx(ids) == bytes);
  ut::Session us;
  hir::Lowerer low(g, us);
  for (size_t k = 0; k < outs.size() && k < ids.size(); k++) {
    Array want = np.eval(outs[k].second, feeds);
    Array got = us.eval(low.get(ids[k]), feeds);
    CHECK(got.shape == want.shape && got.dtype == want.dtype && got.data == want.data);
  }
}

static void new_operators() {
  const DType i32 = DType::Int32, f32 = DType::Float32, f64 = DType::Float64, b = DType::Bool;
  const double inf = INFINITY, nan = NAN;
  Session np;
  // floor and ceil: ties go to the integer below (floor) or above (ceil); -0.0 keeps its sign, and ceil of (-1, 0) is -0.0
  Tensor x = np.array({-2.5, -0.5, -0.0, 0.5, 2.5, -1, 3000, inf, -inf, nan});
  CHECK(x.floor().str() == "[-3., -1., -0., 0., 2., -1., 3000., inf, -inf, nan]");
  CHECK(x.ceil().str() == "[-2., -0., -0., 1., 3., -1., 3000., inf, -inf, nan]");
  CHECK(std::signbit(x.ceil().tolist()[1]) && std::signbit(x.floor().tolist()[2]) && !std::signbit(x.floor().tolist()[3]));
  CHECK(x.floor().dtype() == f32 && np.array({1.5}, f64).ceil().dtype() == f64);
  CHECK(np.array({1, -2}, i32).floor().str() == "[1., -2.]" && np.array({1, -2}, i32).floor().dtype() == f32);   // numpy: float64
  CHECK(np.array({1, -2}, i32).ceil().dtype() == f32);
  // isnan and isinf: floats only; integers and bools are never NaN or infinite
  CHECK(x.isnan().str() == "[False, False, False, False, False, False, False, False, False, True]" && x.isnan().dtype() == b);
  CHECK(x.isinf().str() == "[False, False, False, False, False, False, False, True, True, False]");
  CHECK(np.array({1, 0}, i32).isnan().str() == "[False, False]" && np.array({1, 0}, i32).isinf().dtype() == b);
  CHECK(np.array({1, 0}, b).isinf().str() == "[False, False]");
  CHECK(np.array({1.0, 2.0}, f64).isnan().str() == "[False, False]");
  // pow: the dtype is the promoted one; integers wrap like numpy's int32 and are exact
  Tensor p = pow(np.array({2, 3, -2, 10}), np.array({3, 2, 3, -2}));
  CHECK(p.dtype() == f32 && near(p.tolist(), {8, 9, -8, 0.01}));
  CHECK(pow(np.array({3, -2, 2, 0, 7}, i32), np.array({30, 5, 31, 0, 2}, i32)).str() == "[-1010140999, -32, -2147483648, 1, 49]");
  CHECK(pow(np.array({-1, -1, 1, 2}, i32), np.array({-3, 2, -7, 0}, i32)).str() == "[-1, 1, 1, 1]");   // negative exponents: see the notes
  CHECK(pow(np.array({2, 3}, i32), np.array({2, 2}, i32)).dtype() == i32);
  CHECK(pow(np.array({2, 3}, i32), np.array({2.0, 2.0})).dtype() == f32);
  CHECK(pow(np.array({2, 3}), 2).str() == "[4., 9.]" && pow(2, np.array({1, 2, 3}, i32)).str() == "[2, 4, 8]");
  CHECK(pow(np.array({2, 3}, i32), 2.0).dtype() == f32);   // a float scalar next to an int tensor: default_float
  CHECK(pow(np.array({1.5, 2.0}), 0).str() == "[1., 1.]");
  // the special values of C99 pow, which numpy follows
  Tensor s = np.array({nan, 1, nan, 1, -1, -1, 0, -0.0, -0.0, 0, 2, inf, -inf, -inf, -2});
  Tensor e = np.array({0, nan, 2, inf, inf, -inf, -1, -3, -2, 0.5, -inf, -2, 3, 0.5, inf});
  Tensor sp = pow(s, e);
  CHECK(sp.dtype() == f32);
  CHECK(sp.str() == "[1., 1., nan, 1., 1., 1., inf, -inf, inf, 0., 0., 0., -inf, inf, inf]");
  CHECK(std::signbit(sp.tolist()[7]));   // (-0.0)**-3 is -inf and (-0.0)**-2 is +inf
  CHECK(pow(np.array({-2.0, -0.5, -8}), np.array({0.5, 2, 1.0 / 3})).str() == "[nan, 0.25, nan]");
  CHECK(pow(np.array({-8.0}), np.array({1.0 / 3})).item() != pow(np.array({-8.0}), np.array({1.0 / 3})).item());  // NaN
  // errors (hir): ONNX has no implicit conversion, Pow of bools, floats only for Floor and Ceil and IsNaN/IsInf
  hir::Graph hg;
  int fa = hg.add_input("fa", f32, {2}), ia = hg.add_input("ia", i32, {2}), ba = hg.add_input("ba", b, {2});
  CHECK_THROWS(hg.add_node("Pow", {fa, ia}));
  CHECK_THROWS(hg.add_node("Pow", {ba, ba}));
  CHECK_THROWS(hg.add_node("Floor", {ia}));
  CHECK_THROWS(hg.add_node("Ceil", {ba}));
  CHECK_THROWS(hg.add_node("IsNaN", {ia}));
  CHECK_THROWS(hg.add_node("IsInf", {ba}));
  CHECK_THROWS(hg.add_node("Pow", {fa}));
  CHECK(hg.value(hg.add_node("IsInf", {fa})).dtype == b && hg.value(hg.add_node("Pow", {fa, fa})).dtype == f32);
  // the ONNX round trip, and what the read-back graph computes
  Tensor fx = np.placeholder("x", {2, 3}), ix = np.placeholder("i", {2, 3}, i32);
  Array fxa = Array::from_doubles(f32, {2, 3}, {-2.5, 0.5, inf, nan, -0.0, 4});
  Array ixa = Array::from_doubles(i32, {2, 3}, {2, -3, 4, 5, 0, 1});
  onnx_round_trip(np, {{"fl", fx.floor()}, {"ce", fx.ceil()}, {"nan", fx.isnan()}, {"inf", fx.isinf()}, {"pw", pow(fx.abs(), ix)}, {"ip", pow(ix, 3)}},
             {{"x", fxa}, {"i", ixa}});
}

static void cumsum_and_prod() {
  using hir::Attribute;
  const DType i32 = DType::Int32, i64 = DType::Int64, f32 = DType::Float32, b = DType::Bool;
  const double inf = INFINITY;
  Session np;
  Tensor a = np.array2d({{1, 2, 3}, {4, 5, 6}});
  // cumsum: inclusive running sums along an axis, negative axes, and the flattened array for axis None
  CHECK(a.cumsum(0).str() == "[[1., 2., 3.], [5., 7., 9.]]");
  CHECK(a.cumsum(1).str() == "[[1., 3., 6.], [4., 9., 15.]]" && a.cumsum(-1).str() == a.cumsum(1).str());
  CHECK(a.cumsum().str() == "[1., 3., 6., 10., 15., 21.]" && a.cumsum().shape() == (Shape{6}));
  CHECK(np.array({1, 2, 3, 4}).cumsum().str() == "[1., 3., 6., 10.]");
  CHECK(np.arange(4).cumsum().str() == "[0, 1, 3, 6]" && np.arange(4).cumsum().dtype() == i32);
  CHECK(np.array({1, 0, 1}, b).cumsum().str() == "[1, 1, 2]" && np.array({1, 0, 1}, b).cumsum().dtype() == i32);
  Session s64;
  s64.default_int = i64;
  CHECK(s64.array({1, 2}, i32).cumsum().dtype() == i64);   // narrow ints sum in default_int, like numpy's sum
  CHECK(np.array({1, 2}, i32).cumsum().dtype() == i32);
  V inf_sums = np.array({1, inf, -inf, 2}).cumsum().tolist();   // no NaN from the masked zeros, only from inf - inf
  CHECK(inf_sums.size() == 4 && inf_sums[0] == 1 && inf_sums[1] == inf && std::isnan(inf_sums[2]) && std::isnan(inf_sums[3]));
  CHECK(std::signbit(np.array({-0.0}).cumsum().item()));                         // a sum of one -0.0 is -0.0
  CHECK(np.array({1, 2, 3}).cumsum(0).str() == "[1., 3., 6.]");
  CHECK_THROWS(a.cumsum(2));
  CHECK_THROWS(np.array({1.0}).cumsum(1));
  CHECK(np.scalar(3).cumsum().str() == "[3.]");                  // numpy: a one-element array
  // prod: over all axes, along one axis (keepdims), over several axes; bool and narrow ints give default_int
  CHECK(a.prod().item() == 720 && a.prod().dtype() == f32);
  CHECK(a.prod(0).str() == "[4., 10., 18.]" && a.prod(1).str() == "[6., 120.]" && a.prod(-1).str() == "[6., 120.]");
  CHECK(a.prod(1, true).shape() == (Shape{2, 1}) && a.prod(Axes{0, 1}).item() == 720);
  CHECK(a.prod(Axes{0, 1}, true).shape() == (Shape{1, 1}));
  Tensor c = np.array({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}, {2, 3, 2});
  CHECK(c.prod(1).str() == "[[15., 48.], [693., 960.]]");   // c[i][j][k] = 1 + 6 i + 2 j + k
  CHECK(c.prod(Axes{0, 2}).shape() == (Shape{3}) && c.prod(Axes{0, 2}).tolist() == (V{1 * 2 * 7 * 8, 3 * 4 * 9 * 10, 5 * 6 * 11 * 12}));
  CHECK(np.array({1, 2, 3}, i32).prod().dtype() == i32 && np.array({2, 3}, b).prod().dtype() == i32);
  CHECK(np.array({1, 0, 1}, b).prod().item() == 0);
  CHECK(np.array({2, 1000}, i32).prod().item() == 2000 && np.array({65536, 65536}, i32).prod().item() == 0);   // wraps like int32
  CHECK(std::isinf(np.array({inf, 2}).prod().item()) && std::isnan(np.array({inf, 0}).prod().item()));
  CHECK_THROWS(a.prod(Axes{0, 0}));
  CHECK_THROWS(a.prod(2));
  // hir errors: CumSum needs a constant axis of int32 or int64 and no bool; ReduceProd no bool
  hir::Graph hg;
  int x = hg.add_input("x", f32, {2, 3}), bx = hg.add_input("bx", b, {2, 3});
  int ax0 = hg.add_initializer("", Array(DType::Int64, {}, {Scalar::from_int(DType::Int64, 0)}));
  int axf = hg.add_initializer("", Array(f32, {}, {Scalar::from_double(f32, 0)}));
  int axbig = hg.add_initializer("", Array(DType::Int64, {}, {Scalar::from_int(DType::Int64, 2)}));
  int axpl = hg.add_input("axp", DType::Int64, {});
  CHECK(hg.value(hg.add_node("CumSum", {x, ax0})).shape == (Shape{2, 3}));
  CHECK_THROWS(hg.add_node("CumSum", {bx, ax0}));
  CHECK_THROWS(hg.add_node("CumSum", {x, axf}));
  CHECK_THROWS(hg.add_node("CumSum", {x, axbig}));
  CHECK_THROWS(hg.add_node("CumSum", {x, axpl}));            // the axis must be a constant
  CHECK_THROWS(hg.add_node("CumSum", {x, ax0}, {Attribute::Int("reverse", 2)}));
  CHECK_THROWS(hg.add_node("ReduceProd", {bx}));
  CHECK(hg.value(hg.add_node("ReduceProd", {x}, {Attribute::Int("keepdims", 0)})).shape == Shape{});
  // ONNX round trip and the lowered read-back graph
  Tensor fx = np.placeholder("x", {2, 3});
  Array fxa = Array::from_doubles(f32, {2, 3}, {1, 2, -3, 0.5, -0.0, 4});
  onnx_round_trip(np, {{"cs", fx.cumsum(1)}, {"cp", fx.prod(0, true)}, {"ip", np.arange(6).reshape({2, 3}).cumsum(0)}}, {{"x", fxa}});
}

static void argmax_and_argmin() {
  using hir::Attribute;
  const DType i32 = DType::Int32, i64 = DType::Int64, f32 = DType::Float32, b = DType::Bool;
  const double nan = NAN;
  Session np;
  Tensor a = np.array2d({{1, 5, 3}, {7, 2, 9}});
  CHECK(a.argmax().str() == "5" && a.argmax().dtype() == i32 && a.argmax().ndim() == 0);
  CHECK(a.argmax(0).str() == "[1, 0, 1]" && a.argmax(1).str() == "[1, 2]" && a.argmax(-1).str() == "[1, 2]");
  CHECK(a.argmin(0).str() == "[0, 1, 0]" && a.argmin(1).str() == "[0, 1]" && a.argmin().item() == 0);
  CHECK(a.argmax(1, true).shape() == (Shape{2, 1}) && a.argmax(None, true).shape() == (Shape{1, 1}));
  CHECK(a.argmin(0, true).str() == "[[0, 1, 0]]");
  // ties: the first index; -0.0 and +0.0 are equal
  CHECK(np.array({3, 7, 7, 1}).argmax().item() == 1 && np.array({1, 4, 1}).argmin().item() == 0);
  CHECK(np.array({-0.0, 0.0}).argmax().item() == 0 && np.array({0.0, -0.0}).argmin().item() == 0);
  // NaN wins, the first one: numpy's argmax and argmin
  CHECK(np.array({1, nan, 3}).argmax().item() == 1 && np.array({1, nan, 3}).argmin().item() == 1);
  CHECK(np.array({nan, 5, nan}).argmax().item() == 0 && np.array({5, nan, nan}).argmin().item() == 1);
  // integers and bools: the default int dtype; a session with int64 defaults gives int64
  CHECK(np.array({3, -1, 5}, i32).argmax().item() == 2 && np.array({3, -1, 5}, i32).argmax().dtype() == i32);
  CHECK(np.array({0, 1, 1}, b).argmax().item() == 1 && np.array({0, 1, 1}, b).argmin().item() == 0);
  Session s64;
  s64.default_int = i64;
  CHECK(s64.array({3, 1}).argmax().dtype() == i64);
  // a 3-D case along each axis
  Tensor c = np.array({1, 9, 3, 4, 5, 6, 7, 2, 8, 0, 11, 12}, {2, 3, 2});
  CHECK(c.argmax(1).str() == "[[2, 0], [2, 2]]" && c.argmin(2).str() == "[[0, 0, 0], [1, 1, 0]]");   // numpy's values
  CHECK_THROWS(a.argmax(2));
  CHECK_THROWS(np.scalar(1).argmax(1));
  // select_last_index and the errors come from hir; evaluate the graph with the UOp interpreter
  hir::Graph g;
  int x = g.add_input("x", f32, {4});
  int last = g.add_node("ArgMax", {x}, {Attribute::Int("axis", 0), Attribute::Int("keepdims", 0), Attribute::Int("select_last_index", 1)});
  int first = g.add_node("ArgMax", {x}, {Attribute::Int("axis", 0), Attribute::Int("keepdims", 0)});
  CHECK(g.value(last).dtype == DType::Int64 && g.value(last).shape == Shape{});
  ut::Session us;
  hir::Lowerer low(g, us);
  Array xa = Array::from_doubles(f32, {4}, {3, 7, 7, 1});
  CHECK(us.eval(low.get(last), {{"x", xa}}).data[0].i == 2 && us.eval(low.get(first), {{"x", xa}}).data[0].i == 1);
  CHECK_THROWS(g.add_node("ArgMax", {x}, {Attribute::Int("keepdims", 2)}));
  CHECK_THROWS(g.add_node("ArgMin", {x}, {Attribute::Int("axis", 1)}));
  CHECK_THROWS(g.add_node("ArgMax", {x}, {Attribute::Int("select_last_index", 3)}));
  CHECK(g.value(g.add_node("ArgMin", {x}, {Attribute::Int("keepdims", 0)})).shape == Shape{});
  int bi = g.add_input("bi", b, {4});
  CHECK_THROWS(g.add_node("ArgMax", {bi}));
  // ONNX round trip, and the read-back graph
  Tensor fx = np.placeholder("x", {2, 3});
  Array fxa = Array::from_doubles(f32, {2, 3}, {1, nan, -3, 0.5, -0.0, 4});
  onnx_round_trip(np, {{"am", fx.argmax(1)}, {"an", fx.argmin(0, true)}, {"af", fx.argmax()}}, {{"x", fxa}});
}

static void graph_and_onnx(const std::string& dir) {
  const DType i32 = DType::Int32;
  Session np;
  Tensor x = np.placeholder("x", {2, 3});
  Tensor w = np.array({1, 0, 0, 1, 1, 1}, {3, 2});
  Tensor bias = np.array({0.5, -0.5});
  Tensor y = softmax(matmul(x, w) + bias);
  // the high-level graph has ONNX operators, not UOps
  std::string g = y.dump();
  CHECK(g.find("MatMul") != std::string::npos && g.find("Softmax") != std::string::npos && g.find("Add") != std::string::npos);
  CHECK(g.find("input %x : float32[2,3]") != std::string::npos);
  CHECK(y.shape() == (Shape{2, 2}) && y.dtype() == DType::Float32);
  // constants are shared
  size_t before = np.graph().nodes().size();
  Tensor t2 = (y * 2 + y * 2);
  CHECK(np.graph().nodes().size() == before + 3);
  // lowering happens on demand: before eval nothing was lowered; afterwards the UOps exist
  Array fed = Array::from_doubles(DType::Float32, {2, 3}, {1, 2, 3, 4, 5, 6});
  Array r = np.eval(y, {{"x", fed}});
  CHECK(r.shape == (Shape{2, 2}));
  CHECK(std::fabs(r.data[0].f + r.data[1].f - 1) < 1e-6);
  CHECK(!y.dump_uops().empty());
  // export
  std::string onnx = np.to_onnx({{"y", y}});
  CHECK(onnx.size() > 50);
  CHECK(static_cast<unsigned char>(onnx[0]) == 0x08 && static_cast<unsigned char>(onnx[1]) == 8);  // ir_version = 8
  CHECK(onnx.find("MatMul") != std::string::npos && onnx.find("Softmax") != std::string::npos && onnx.find("nfcuop") != std::string::npos);
  CHECK(onnx.find("Identity") != std::string::npos);   // the named output
  std::string only_t2 = np.to_onnx({{"t2", t2}});
  CHECK(only_t2.find("Softmax") != std::string::npos);  // t2 depends on y
  Session np2;
  Tensor lone = np2.placeholder("p", {2}) + 1;
  std::string small = np2.to_onnx({{"q", lone}});
  CHECK(small.find("Softmax") == std::string::npos && small.find("\x01p") != std::string::npos);
  CHECK_THROWS(np.to_onnx({}));
  CHECK_THROWS(np.to_onnx({{"y", y}, {"y", y}}));            // the same output name twice
  CHECK(!np.to_onnx({{"w2", w}}).empty());                  // an initializer is passed through Identity
  // hir errors
  hir::Graph hg;
  int a = hg.add_input("a", DType::Float32, {2, 3});
  int i = hg.add_input("i", DType::Int32, {2, 3});
  CHECK_THROWS(hg.add_node("Add", {a, i}));                  // ONNX has no implicit conversion
  CHECK_THROWS(hg.add_node("Sqrt", {i}));
  CHECK_THROWS(hg.add_node("Nonsense", {a}));
  CHECK_THROWS(hg.add_node("Reshape", {a, a}));              // the shape must be an initializer
  CHECK_THROWS(hg.add_input("a", DType::Float32, {1}));      // duplicate name
  CHECK_THROWS(hg.add_node("MatMul", {a, a}));
  CHECK_THROWS(hg.add_node("Softmax", {i}));
  int s = hg.add_node("Add", {a, a});
  CHECK(hg.value(s).shape == (Shape{2, 3}) && hg.producer(s) == 0 && hg.producer(a) == -1);

  if (!dir.empty()) {
    // models for tests/uop/onnx_check.py: onnxruntime must compute what the UOp interpreter computes
    struct Case { std::string name; Session s; std::map<std::string, Tensor> out; std::map<std::string, Array> feeds; };
    auto write = [&](const std::string& path, const std::string& bytes) { std::ofstream f(path, std::ios::binary); f.write(bytes.data(), static_cast<std::streamsize>(bytes.size())); };
    auto jarr = [](const Array& a) {
      std::string o = "{\"dtype\":\"" + std::string(name(a.dtype)) + "\",\"shape\":[";
      for (size_t k = 0; k < a.shape.size(); k++) o += (k ? "," : "") + std::to_string(a.shape[k]);
      o += "],\"data\":[";
      for (size_t k = 0; k < a.data.size(); k++) {
        char buf[64];
        if (is_float(a.dtype)) std::snprintf(buf, sizeof buf, "%.17g", a.data[k].f);
        else std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(a.data[k].i));
        std::string num = buf;
        if (num == "nan" || num == "-nan") num = "null"; else if (num == "inf") num = "1e999"; else if (num == "-inf") num = "-1e999";
        o += (k ? "," : "") + num;
      }
      return o + "]}";
    };
    auto emit = [&](const std::string& name, Session& s, const std::vector<std::pair<std::string, Tensor>>& outs, const std::map<std::string, Array>& feeds) {
      write(dir + "/" + name + ".onnx", s.to_onnx(outs));
      std::string j = "{\"inputs\":{";
      bool first = true;
      for (const auto& f : feeds) { j += (first ? "" : ",") + ("\"" + f.first + "\":" + jarr(f.second)); first = false; }
      j += "},\"outputs\":{";
      first = true;
      for (const auto& o : outs) { j += (first ? "" : ",") + ("\"" + o.first + "\":" + jarr(s.eval(o.second, feeds))); first = false; }
      write(dir + "/" + name + ".json", j + "}}");
    };
    Array fx = Array::from_doubles(DType::Float32, {2, 3}, {1, -2, 3, 4, -5, 6});
    {  // an MLP
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3});
      Tensor w1 = s.array({0.1, -0.2, 0.3, 0.4, 0.5, -0.6, 0.7, 0.8, -0.9, 1.0, 1.1, 1.2}, {3, 4});
      Tensor b1 = s.array({0.1, 0.2, -0.3, 0.4});
      Tensor w2 = s.array({1, -1, 0.5, 2, -0.5, 1, 0.25, 0.75}, {4, 2});
      Tensor h = relu(matmul(x2, w1) + b1);
      emit("mlp", s, {{"logits", matmul(h, w2)}, {"probs", softmax(matmul(h, w2))}}, {{"x", fx}});
    }
    {  // broadcasting arithmetic, scalars, comparisons and where
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3});
      Tensor v = s.array({10, 20, 30});
      emit("arith", s, {{"a", x2 * 2 + v}, {"b", (x2 - 1.5) / v}, {"c", where(x2 > 0, x2, -x2)}, {"d", (x2 >= 3) & (x2 != 4)}, {"e", maximum(x2, v - 25)}, {"f", x2.clip(-1, 3)}, {"g", x2.abs().sqrt()}}, {{"x", fx}});
    }
    {  // reductions and shape ops
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3});
      Tensor t = x2.reshape({3, 2}).T();
      emit("shape", s, {{"sum0", x2.sum(0)}, {"mean1", x2.mean(1, true)}, {"max", x2.max()}, {"min1", x2.min(1)}, {"var", x2.var(Axes{1})}, {"t", t}, {"sq", x2.expand_dims(0).squeeze(0)}, {"bc", x2.sum(1).broadcast_to({2, 2})}}, {{"x", fx}});
    }
    {  // integers: truncating Div, both Mod flavours, the numpy floor forms
      Session s;
      Tensor n = s.placeholder("n", {4}, i32), d = s.placeholder("d", {4}, i32);
      Array an = Array::from_doubles(i32, {4}, {-7, 7, -7, 7}), ad = Array::from_doubles(i32, {4}, {2, -2, -2, 2});
      emit("ints", s, {{"floordiv", floor_divide(n, d)}, {"mod", n % d}, {"sum", n + d}, {"mul", n * d}, {"cmp", n < d}, {"cast", n.astype(DType::Float32) / 2}}, {{"n", an}, {"d", ad}});
    }
    {  // math
      Session s;
      Tensor x2 = s.placeholder("x", {5});
      Array av = Array::from_doubles(DType::Float32, {5}, {-2, -0.5, 0.25, 0.5, 2});
      emit("math", s, {{"exp", x2.exp()}, {"log", (x2.abs() + 1).log()}, {"sin", x2.sin()}, {"cos", x2.cos()}, {"tanh", x2.tanh()}, {"sigmoid", x2.sigmoid()}, {"lsm", x2.log_softmax(0)}}, {{"x", av}});
    }
    {  // slicing and concatenation
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3, 4});
      Array am = Array::from_doubles(DType::Float32, {2, 3, 4}, [] { V v; for (int k = 0; k < 24; k++) v.push_back(k * 0.5); return v; }());
      emit("slice", s, {{"a", x2.slice(2, 1, 3)}, {"b", x2.slice(2, None, None, 2)}, {"c", x2.slice(2, None, None, -1)}, {"d", x2.slice(1, -2, None)}, {"e", x2.at(1)}, {"f", concatenate({x2, x2 * 2}, 1)}, {"g", stack({x2.at(0), x2.at(1)}, 2)}}, {{"x", am}});
    }
    {  // floor, ceil, isnan, isinf and pow, with NaN, infinities and signed zeros
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3}), i2 = s.placeholder("i", {2, 3}, i32);
      Array ax = Array::from_doubles(DType::Float32, {2, 3}, {-2.5, 0.5, INFINITY, NAN, -0.0, 4});
      Array ai = Array::from_doubles(i32, {2, 3}, {2, -3, 4, 5, 0, 1});
      emit("floor_pow", s, {{"fl", x2.floor()}, {"ce", x2.ceil()}, {"nan", x2.isnan()}, {"inf", x2.isinf()}, {"pw", pow(x2.abs(), i2)}, {"ip", pow(i2, 3)}, {"pf", pow(x2, 0.5)}}, {{"x", ax}, {"i", ai}});
    }
    {  // cumsum (inclusive, with an axis, and flattened) and prod, with infinities
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3});
      Array ax = Array::from_doubles(DType::Float32, {2, 3}, {1, INFINITY, -2, 0.5, -0.0, 4});
      emit("cumsum_prod", s, {{"cs0", x2.cumsum(0)}, {"cs1", x2.cumsum(1)}, {"csf", x2.cumsum()}, {"p0", x2.prod(0, true)}, {"pall", x2.prod()}}, {{"x", ax}});
    }
    {  // argmax and argmin along each axis, with ties and without NaN
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3});
      Array ax = Array::from_doubles(DType::Float32, {2, 3}, {1, 5, 5, 7, 2, -9});
      emit("argext", s, {{"amax0", x2.argmax(0)}, {"amin1", x2.argmin(1, true)}, {"amax", x2.argmax()}}, {{"x", ax}});
    }
    {  // matmul variants
      Session s;
      Tensor x2 = s.placeholder("x", {2, 3, 4});
      Tensor w3 = s.array([] { V v; for (int k = 0; k < 8; k++) v.push_back(k - 3.5); return v; }(), {4, 2});
      Tensor vec = s.array({1, 2, 3, 4});
      Array am = Array::from_doubles(DType::Float32, {2, 3, 4}, [] { V v; for (int k = 0; k < 24; k++) v.push_back(k * 0.25 - 2); return v; }());
      emit("matmul", s, {{"batch", matmul(x2, w3)}, {"vec", matmul(x2, vec)}, {"gram", matmul(x2, x2.transpose({0, 2, 1}))}, {"dot", matmul(vec, vec)}}, {{"x", am}});
    }
  }
}

int main(int argc, char** argv) {
  numpy_api();
  default_dtypes();
  slicing_and_concat();
  new_operators();
  cumsum_and_prod();
  argmax_and_argmin();
  graph_and_onnx(argc > 1 ? argv[1] : "");
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
