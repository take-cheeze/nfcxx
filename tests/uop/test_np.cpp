// nfcuop stage 3 (shapes, movement ops, reductions, evaluate_array) and the numpy-like API of nfcuop_np.hpp.
#include <cmath>
#include <cstdio>
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

static void stage3_ir() {
  Graph g;
  const DType f32 = DType::Float32, i32 = DType::Int32;
  const UOp* x = g.var("x", f32, {2, 3});
  // shape inference and errors
  CHECK(g.reshape(x, {3, 2})->shape == (Shape{3, 2}));
  CHECK(g.permute(x, {1, 0})->shape == (Shape{3, 2}));
  CHECK(g.expand(g.reshape(x, {2, 1, 3}), {2, 4, 3})->shape == (Shape{2, 4, 3}));
  CHECK(g.reduce_sum(x, {1})->shape == (Shape{2, 1}));
  CHECK(g.reduce_max(x, {1, 0})->shape == (Shape{1, 1}));
  CHECK(g.reduce_sum(x, {1, 0}) == g.reduce_sum(x, {0, 1}));  // axes are sorted before interning
  CHECK(g.add(x, x)->shape == (Shape{2, 3}));
  CHECK_THROWS(g.reshape(x, {4, 2}));
  CHECK_THROWS(g.reshape(x, {0, 6}));
  CHECK_THROWS(g.permute(x, {0, 0}));
  CHECK_THROWS(g.permute(x, {0}));
  CHECK_THROWS(g.expand(x, {4, 3}));
  CHECK_THROWS(g.expand(x, {2, 3, 1}));
  CHECK_THROWS(g.reduce_sum(x, {2}));
  CHECK_THROWS(g.reduce_sum(x, {1, 1}));
  CHECK_THROWS(g.add(x, g.var("y", f32, {3, 2})));
  CHECK_THROWS(g.add(x, g.fconst(f32, 1)));  // no implicit broadcasting in the IR
  CHECK_THROWS(g.var("z", f32, {2, 0}));
  CHECK(g.var("x", f32, {2, 3}) == x);
  CHECK(g.var("x", f32, {3, 2}) != x);
  CHECK(g.fconst(f32, 1, {2}) != g.fconst(f32, 1, {3}));
  // evaluation
  Array in = Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6});
  std::map<std::string, Array> env{{"x", in}};
  auto vals = [&](const UOp* u) { V v; for (const Scalar& s : evaluate_array(u, env).data) v.push_back(s.as_double()); return v; };
  CHECK(vals(g.permute(x, {1, 0})) == (V{1, 4, 2, 5, 3, 6}));
  CHECK(vals(g.reshape(x, {3, 2})) == (V{1, 2, 3, 4, 5, 6}));
  CHECK(vals(g.expand(g.reshape(x, {2, 3, 1}), {2, 3, 2})) == (V{1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6}));
  CHECK(vals(g.reduce_sum(x, {0})) == (V{5, 7, 9}));
  CHECK(vals(g.reduce_sum(x, {1})) == (V{6, 15}));
  CHECK(vals(g.reduce_max(x, {1})) == (V{3, 6}));
  CHECK(vals(g.reduce_sum(x, {0, 1})) == (V{21}));
  CHECK(vals(g.permute(g.reshape(x, {1, 2, 3}), {2, 0, 1})) == (V{1, 4, 2, 5, 3, 6}));
  CHECK_THROWS(evaluate_array(x));  // unbound
  CHECK_THROWS(evaluate_array(x, {{"x", Array::from_doubles(f32, {3, 2}, {1, 2, 3, 4, 5, 6})}}));  // wrong shape
  CHECK_THROWS(evaluate(x, {}));    // a tensor: evaluate() is for scalars
  // int sums wrap
  const UOp* big = g.iconst(i32, 2147483647, {4});
  CHECK(evaluate_array(g.reduce_sum(big, {0})).data[0] == Scalar::from_int(i32, -4));  // 4 * (2^31 - 1) mod 2^32
  // dump shows shapes
  const UOp* e = g.reduce_sum(g.permute(x, {1, 0}), {0});
  const char* golden =
      "  0 VAR    float32 () x shape=[2,3]\n"
      "  1 PERMUTE float32 (0) shape=[3,2] perm=[1,0]\n"
      "  2 REDUCE_SUM float32 (1) shape=[1,2] axes=[0]\n";
  CHECK(dump(e) == golden);
  if (dump(e) != golden) std::printf("%s", dump(e).c_str());
}

static void stage3_rewrite() {
  Graph g;
  const DType f32 = DType::Float32, i32 = DType::Int32;
  auto rw = [&](const UOp* u) { return graph_rewrite(g, symbolic(), u); };
  const UOp* x = g.var("x", f32, {2, 3});
  CHECK(rw(g.reshape(x, {2, 3})) == x);
  CHECK(rw(g.reshape(g.reshape(x, {3, 2}), {6})) == g.reshape(x, {6}));
  CHECK(rw(g.reshape(g.reshape(x, {3, 2}), {2, 3})) == x);
  CHECK(rw(g.permute(x, {0, 1})) == x);
  CHECK(rw(g.permute(g.permute(x, {1, 0}), {1, 0})) == x);
  const UOp* y = g.var("y", f32, {2, 3, 4});
  CHECK(rw(g.permute(g.permute(y, {2, 0, 1}), {1, 2, 0})) == y);   // composes to the identity
  CHECK(rw(g.permute(g.permute(y, {2, 0, 1}), {2, 1, 0})) == g.permute(y, {1, 0, 2}));
  CHECK(rw(g.expand(g.reshape(x, {2, 3, 1}), {2, 3, 1})) == g.reshape(x, {2, 3, 1}));
  CHECK(rw(g.reduce_sum(g.reshape(x, {2, 1, 3}), {1})) == g.reshape(x, {2, 1, 3}));  // reducing a size-1 axis
  CHECK(rw(g.reduce_sum(x, {0})) == g.reduce_sum(x, {0}));
  // constants stay constants under movement and reduction
  CHECK(rw(g.expand(g.reshape(g.fconst(f32, 3), {}), {})) == g.fconst(f32, 3));
  CHECK(rw(g.permute(g.fconst(f32, 3, {2, 5}), {1, 0})) == g.fconst(f32, 3, {5, 2}));
  CHECK(rw(g.reshape(g.fconst(f32, 3, {2, 5}), {10})) == g.fconst(f32, 3, {10}));
  CHECK(rw(g.reduce_max(g.fconst(f32, 3, {2, 5}), {0})) == g.fconst(f32, 3, {1, 5}));
  CHECK(rw(g.reduce_sum(g.iconst(i32, 3, {2, 5}), {0, 1})) == g.iconst(i32, 30, {1, 1}));
  CHECK(rw(g.reduce_sum(g.fconst(f32, 3, {2, 5}), {0})) == g.reduce_sum(g.fconst(f32, 3, {2, 5}), {0}));  // float sums round
  // the scalar rules work on tensors, and keep the shape
  CHECK(rw(g.add(x, g.fconst(f32, 0, {2, 3}))) == x);
  CHECK(rw(g.mul(g.fconst(f32, 2, {2, 3}), g.fconst(f32, 4, {2, 3}))) == g.fconst(f32, 8, {2, 3}));
  const UOp* k = g.var("k", i32, {4, 2});
  CHECK(rw(g.sub(k, k)) == g.iconst(i32, 0, {4, 2}));
  CHECK(rw(g.mul(k, g.iconst(i32, 0, {4, 2}))) == g.iconst(i32, 0, {4, 2}));
  CHECK(rw(g.cmplt(k, k)) == g.iconst(DType::Bool, 0, {4, 2}));
  CHECK(rw(g.add(g.add(k, g.iconst(i32, 1, {4, 2})), g.iconst(i32, 2, {4, 2}))) == g.add(k, g.iconst(i32, 3, {4, 2})));
  CHECK(rw(g.where(g.iconst(DType::Bool, 1, {4, 2}), k, g.neg(k))) == k);

  // differential: random movement/reduction/elementwise chains evaluate the same before and after symbolic()
  unsigned long long seed = 777;
  auto rnd = [&](unsigned n) { seed = seed * 6364136223846793005ull + 1442695040888963407ull; return static_cast<unsigned>((seed >> 33) % n); };
  const UOp* a = g.var("a", i32, {2, 3, 2});
  std::vector<int> data(12);
  Array arr;
  arr.dtype = i32;
  arr.shape = {2, 3, 2};
  int compared = 0;
  for (int t = 0; t < 300; t++) {
    const UOp* e = a;
    for (int step = 0; step < 6; step++) {
      switch (rnd(9)) {
        case 0: {
          size_t r = e->shape.size();
          Shape perm;
          for (size_t k2 = 0; k2 < r; k2++) perm.push_back(static_cast<int64_t>(rnd(2) ? (k2 + 1) % r : r - 1 - k2));
          std::vector<bool> seen(r, false);
          bool ok = true;
          for (int64_t q : perm) { ok = ok && !seen[q]; seen[q] = true; }
          if (ok) e = g.permute(e, perm);
          break;
        }
        case 1: { int64_t n = numel(e->shape); e = g.reshape(g.reshape(e, {n}), {1, n}); break; }
        case 2: { Shape ax{static_cast<int64_t>(rnd(static_cast<unsigned>(e->shape.size())))}; e = g.reduce_sum(e, ax); break; }
        case 3: { Shape ax{static_cast<int64_t>(rnd(static_cast<unsigned>(e->shape.size())))}; e = g.reduce_max(e, ax); break; }
        case 4: e = g.add(e, g.iconst(i32, static_cast<int>(rnd(3)), e->shape)); break;
        case 5: e = g.mul(e, g.iconst(i32, static_cast<int>(rnd(3)) - 1, e->shape)); break;
        case 6: e = g.sub(e, e); e = g.add(e, g.neg(e)); break;
        case 7: { Shape s = e->shape; if (s.back() == 1) { s.back() = 3; e = g.expand(e, s); } break; }
        default: e = g.where(g.cmplt(e, g.iconst(i32, 2, e->shape)), e, g.neg(e)); break;
      }
    }
    const UOp* s = rw(e);
    CHECK(rw(s) == s);
    for (int trial = 0; trial < 3; trial++) {
      arr.data.clear();
      for (int k2 = 0; k2 < 12; k2++) arr.data.push_back(Scalar::from_int(i32, static_cast<int>(rnd(9)) - 4));
      Array want = evaluate_array(e, {{"a", arr}}), got = evaluate_array(s, {{"a", arr}});
      compared++;
      CHECK(want.shape == got.shape && want.data == got.data);
    }
  }
  std::printf("  tensor differential: %d comparisons\n", compared);
}

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
  CHECK(np.arange(4).str() == "[0., 1., 2., 3.]");
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
  size_t before = np.graph().size();
  Tensor lazy = (a * 2 + 1).sum();
  CHECK(np.graph().size() > before);
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
  CHECK(graph_rewrite(np.graph(), symbolic(), plain.uop()) == a.uop());
  Session other;
  CHECK_THROWS(a + other.scalar(1));
  CHECK_THROWS(Tensor().numpy());
  CHECK(!a.dump().empty());
}

int main() {
  stage3_ir();
  stage3_rewrite();
  numpy_api();
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
