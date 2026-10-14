// Reverse-mode automatic differentiation by onnxsim (nfcuop_onnxgrad.hpp, docs/notes/uop-autodiff.md): finite-difference checks in
// float64 of every operator onnxsim has a rule for and hir has, hand-derived gradients, second derivatives, the operators that
// have no rule (the library's message), errors, the C backend equal bit for bit to the interpreter, and models whose outputs are
// a loss and its gradients, written to the directory given as argv[1] for tests/uop/onnx_check.py.
// Without onnxsim (neither libnfconnxsim.so nor python3 with onnx and onnxsim) everything that differentiates prints SKIP; the
// argument checks that need no backend still run.
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_np.hpp"
#include "nfcuop_onnxgrad.hpp"

using namespace nfcuop;
using namespace nfcuop::np;

static int checks = 0, failed = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond)) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
// the expression must throw an Error whose message contains `frag`
#define CHECK_ERR(expr, frag)                                              \
  do {                                                                     \
    checks++;                                                              \
    std::string msg_;                                                      \
    bool threw_ = false;                                                   \
    try { (void)(expr); } catch (const Error& e) { threw_ = true; msg_ = e.what(); } \
    if (!threw_ || msg_.find(frag) == std::string::npos) { failed++; std::printf("FAIL %s:%d: %s: error \"%s\" lacks \"%s\"\n", __FILE__, __LINE__, #expr, msg_.c_str(), frag); } \
  } while (0)

using V = std::vector<double>;
using Ts = std::vector<Tensor>;
static const DType f32 = DType::Float32, f64 = DType::Float64, i32 = DType::Int32, i64 = DType::Int64;

static bool near(const V& a, const V& b, double tol = 1e-12) {
  if (a.size() != b.size()) return false;
  for (size_t k = 0; k < a.size(); k++)
    if (!(std::fabs(a[k] - b[k]) <= tol * (1 + std::fabs(b[k])))) return false;
  return true;
}
static void show(const char* what, const V& v) {
  std::printf("  %s:", what);
  for (double d : v) std::printf(" %.9g", d);
  std::printf("\n");
}
#define CHECK_VALS(got, ...) do { V g_ = (got), w_ = __VA_ARGS__; bool ok_ = near(g_, w_); CHECK(ok_); if (!ok_) { show("got", g_); show("want", w_); } } while (0)

// deterministic data in [-1, 1], away from 0 (so that the kinks of relu are not near a sample)
static V rand_vec(int64_t n, unsigned seed) {
  V v;
  uint64_t s = 0x9E3779B97F4A7C15ull * (seed + 1);
  for (int64_t k = 0; k < n; k++) {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    double r = static_cast<double>(s >> 11) / 9007199254740992.0 * 2 - 1;
    v.push_back((r < 0 ? -1 : 1) * (0.1 + 0.9 * std::fabs(r)));
  }
  return v;
}
static Array arr(DType d, const Shape& s, const V& v) { return Array::from_doubles(d, s, v); }

// a loss from any tensor: the sum of its elements times fixed unequal weights (so that the incoming gradient is not all ones)
static Tensor wsum(Session& s, const Tensor& t) {
  if (t.ndim() == 0) return t;
  V w;
  for (int64_t k = 0; k < t.size(); k++) w.push_back(0.6 + 0.37 * std::sin(1.7 * static_cast<double>(k) + 0.3));
  return (t * s.array(w, t.shape())).sum();
}

// ---- (a) finite differences ----

static double max_fd_err = 0;
static int fd_cases = 0, fd_elements = 0;
using Fn = std::function<Tensor(Session&, const Ts&)>;

static void fd_case(const std::string& name, const std::vector<Shape>& shapes, const Fn& fn, unsigned seed = 1) {
  Session s;
  s.default_float = f64;
  s.default_int = i64;
  Ts xs;
  std::map<std::string, Array> feeds;
  for (size_t k = 0; k < shapes.size(); k++) {
    std::string nm = "x" + std::to_string(k);
    xs.push_back(s.placeholder(nm, shapes[k]));
    feeds[nm] = arr(f64, shapes[k], rand_vec(numel(shapes[k]), seed * 7 + static_cast<unsigned>(k)));
  }
  Tensor loss = wsum(s, fn(s, xs));
  Ts gs = grad(loss, xs);
  Ts all{loss};
  all.insert(all.end(), gs.begin(), gs.end());
  std::vector<Array> vals = s.eval_all(all, feeds);
  bool ok = vals[0].shape.empty();
  const double h = 1e-6;
  double worst = 0;
  for (size_t k = 0; k < xs.size(); k++) {
    ok = ok && gs[k].shape() == xs[k].shape() && gs[k].dtype() == f64 && vals[k + 1].shape == shapes[k];
    if (!ok) break;
    const std::string nm = "x" + std::to_string(k);
    for (size_t j = 0; j < feeds[nm].data.size(); j++) {
      std::map<std::string, Array> f = feeds;
      f[nm].data[j] = Scalar::from_double(f64, feeds[nm].data[j].f + h);
      double up = s.eval(loss, f).data[0].f;
      f[nm].data[j] = Scalar::from_double(f64, feeds[nm].data[j].f - h);
      double dn = s.eval(loss, f).data[0].f;
      double num = (up - dn) / (2 * h), ana = vals[k + 1].data[j].f;
      double err = std::fabs(ana - num) / (1 + std::fabs(num));
      worst = std::max(worst, err);
      fd_elements++;
    }
  }
  max_fd_err = std::max(max_fd_err, worst);
  fd_cases++;
  CHECK(ok && worst <= 1e-6);
  if (!ok || worst > 1e-6) std::printf("  FD case %s: max relative error %g\n", name.c_str(), worst);
}

static Tensor pos(const Tensor& x) { return x * x + 0.5; }  // strictly positive

static void finite_differences() {
  static const Shape S23{2, 3}, S3{3}, S21{2, 1}, S{};
  // unary
  fd_case("neg", {S23}, [](Session&, const Ts& x) { return -x[0]; });
  fd_case("relu", {S23}, [](Session&, const Ts& x) { return x[0].relu(); });
  fd_case("sqrt", {S23}, [](Session&, const Ts& x) { return pos(x[0]).sqrt(); });
  fd_case("exp", {S23}, [](Session&, const Ts& x) { return x[0].exp(); });
  fd_case("log", {S23}, [](Session&, const Ts& x) { return pos(x[0]).log(); });
  fd_case("tanh", {S23}, [](Session&, const Ts& x) { return x[0].tanh(); });
  fd_case("sigmoid", {S23}, [](Session&, const Ts& x) { return x[0].sigmoid(); });
  fd_case("square", {S23}, [](Session&, const Ts& x) { return x[0].square(); });
  fd_case("reciprocal", {S23}, [](Session&, const Ts& x) { return pos(x[0]).reciprocal(); });
  fd_case("clip", {S23}, [](Session&, const Ts& x) { return x[0].clip(-0.4, 0.5); });
  fd_case("scalar-input", {S}, [](Session&, const Ts& x) { return x[0].exp() * x[0]; });
  // binary, with and without broadcasting
  fd_case("add", {S23, S23}, [](Session&, const Ts& x) { return x[0] + x[1]; });
  fd_case("add-bcast-row", {S23, S3}, [](Session&, const Ts& x) { return x[0] + x[1]; });
  fd_case("add-bcast-col", {S23, S21}, [](Session&, const Ts& x) { return x[0] + x[1]; });
  fd_case("add-bcast-scalar", {S23, S}, [](Session&, const Ts& x) { return x[0] + x[1]; });
  fd_case("add-bcast-both", {S21, S3}, [](Session&, const Ts& x) { return x[0] + x[1]; });
  fd_case("sub", {S23, S3}, [](Session&, const Ts& x) { return x[0] - x[1]; });
  fd_case("sub-col", {S21, S23}, [](Session&, const Ts& x) { return x[0] - x[1]; });
  fd_case("mul", {S23, S3}, [](Session&, const Ts& x) { return x[0] * x[1]; });
  fd_case("mul-both", {S21, S3}, [](Session&, const Ts& x) { return x[0] * x[1]; });
  fd_case("div", {S23, S3}, [](Session&, const Ts& x) { return x[0] / pos(x[1]); });
  fd_case("div-num-bcast", {S3, S23}, [](Session&, const Ts& x) { return x[0] / pos(x[1]); });
  // matmul: 2-D and batched, the batch dimensions broadcast (a 1-D operand has no rule)
  fd_case("matmul-2d-2d", {S23, Shape{3, 4}}, [](Session&, const Ts& x) { return matmul(x[0], x[1]); });
  fd_case("matmul-3d-2d", {Shape{2, 3, 4}, Shape{4, 2}}, [](Session&, const Ts& x) { return matmul(x[0], x[1]); });
  fd_case("matmul-2d-3d", {Shape{3, 4}, Shape{2, 4, 5}}, [](Session&, const Ts& x) { return matmul(x[0], x[1]); });
  fd_case("matmul-3d-3d", {Shape{2, 3, 4}, Shape{2, 4, 5}}, [](Session&, const Ts& x) { return matmul(x[0], x[1]); });
  fd_case("matmul-bcast-batch", {Shape{2, 1, 3, 4}, Shape{5, 4, 2}}, [](Session&, const Ts& x) { return matmul(x[0], x[1]); });
  fd_case("matmul-bcast-1-batch", {Shape{1, 3, 4}, Shape{2, 4, 2}}, [](Session&, const Ts& x) { return matmul(x[0], x[1]); });
  fd_case("matmul-gram", {Shape{2, 3, 4}}, [](Session&, const Ts& x) { return matmul(x[0], x[0].transpose({0, 2, 1})); });
  // shape operators
  fd_case("transpose", {S23}, [](Session&, const Ts& x) { return x[0].T() * x[0].T(); });
  fd_case("transpose-perm", {Shape{2, 3, 4}}, [](Session&, const Ts& x) { return x[0].transpose({2, 0, 1}).tanh(); });
  fd_case("reshape", {S23}, [](Session&, const Ts& x) { return x[0].reshape({3, 2}).exp(); });
  fd_case("abs", {S23}, [](Session&, const Ts& x) { return x[0].abs(); });   // onnxsim's Abs rule (master): away from 0 with random inputs
  fd_case("max-binary", {S23}, [](Session&, const Ts& x) { return maximum(x[0], x[0] * 0.5); });
  fd_case("min-binary", {S23}, [](Session&, const Ts& x) { return minimum(x[0], x[0] * 0.5); });
  fd_case("concat", {S23}, [](Session&, const Ts& x) { return concatenate({x[0], x[0] * x[0]}, 0); });
  fd_case("flatten", {S23}, [](Session&, const Ts& x) { return x[0].flatten().tanh(); });
  // reductions
  fd_case("sum-all", {S23}, [](Session&, const Ts& x) { return (x[0] * x[0]).sum(); });
  fd_case("sum-axis0", {S23}, [](Session&, const Ts& x) { return (x[0] * x[0]).sum(0); });
  fd_case("sum-axis1-keep", {S23}, [](Session&, const Ts& x) { return (x[0] * x[0]).sum(1, true); });
  fd_case("sum-axes", {Shape{2, 3, 4}}, [](Session&, const Ts& x) { return x[0].tanh().sum(Axes{0, 2}); });
  fd_case("mean-all", {S23}, [](Session&, const Ts& x) { return (x[0] * x[0]).mean(); });
  fd_case("mean-axis", {Shape{2, 3, 4}}, [](Session&, const Ts& x) { return x[0].tanh().mean(1) * 3.0; });
  fd_case("mean-keep", {S23}, [](Session&, const Ts& x) { return x[0] - x[0].mean(1, true); });
  fd_case("var", {S23}, [](Session&, const Ts& x) { return x[0].var(Axes{1}); });
  fd_case("stddev", {S23}, [](Session&, const Ts& x) { return x[0].stddev(); });
  fd_case("reduce-max", {S23}, [](Session&, const Ts& x) { return x[0].max(1); });
  fd_case("reduce-min", {S23}, [](Session&, const Ts& x) { return x[0].min(1); });
  fd_case("log-softmax", {S23}, [](Session&, const Ts& x) { return x[0].log_softmax(1); });
  fd_case("softmax-last", {S23}, [](Session&, const Ts& x) { return x[0].softmax(); });
  fd_case("softmax-axis0", {Shape{3, 4}}, [](Session&, const Ts& x) { return x[0].softmax(0); });
  fd_case("softmax-axis1-3d", {Shape{2, 3, 4}}, [](Session&, const Ts& x) { return x[0].softmax(1); });
  // composition
  fd_case("shared", {S23}, [](Session&, const Ts& x) { Tensor y = x[0].exp(); return y * y + y; });
  fd_case("shared-3-uses", {S3}, [](Session&, const Ts& x) { return x[0] * x[0] * x[0] + x[0].exp() * x[0]; });
  fd_case("diamond", {S23}, [](Session&, const Ts& x) { Tensor a = x[0].tanh(); return (a + 1.0) * (a - 2.0) / (a * a + 3.0); });
  fd_case("chain", {S23, Shape{3, 2}}, [](Session&, const Ts& x) { return matmul(x[0], x[1]).tanh().softmax(0).log(); });
  fd_case("layernorm", {Shape{3, 4}, Shape{4}, Shape{4}}, [](Session&, const Ts& x) {
    Tensor mu = x[0].mean(1, true), d = x[0] - mu;
    return d / (d * d).mean(1, true).sqrt() * x[1] + x[2];
  });
  fd_case("batched-attention", {Shape{2, 3, 4}, Shape{2, 3, 4}, Shape{2, 3, 4}}, [](Session&, const Ts& x) {
    return matmul(softmax(matmul(x[0], x[1].transpose({0, 2, 1})) * 0.5), x[2]);
  });
  fd_case("poly-unused-input", {S3, S3}, [](Session&, const Ts& x) { return x[0] * x[0]; });  // x1 is not on the path: a zero gradient
  // a 2-layer MLP with softmax cross entropy: Softmax, Log and a one-hot product (LogSoftmax has no rule)
  fd_case("mlp-tanh-xent", {Shape{3, 5}, Shape{5}, Shape{5, 3}, Shape{3}}, [](Session& s, const Ts& p) {
    Tensor x = s.array(rand_vec(12, 99), {4, 3});
    Tensor onehot = s.array({1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0}, {4, 3});
    Tensor h = tanh(matmul(x, p[0]) + p[1]);
    Tensor logits = matmul(h, p[2]) + p[3];
    return -(onehot * logits.softmax(1).log()).sum() / 4.0;
  });
  fd_case("mlp-relu-xent", {Shape{3, 6}, Shape{6}, Shape{6, 3}, Shape{3}}, [](Session& s, const Ts& p) {
    Tensor x = s.array(rand_vec(15, 98), {5, 3});
    Tensor onehot = s.array({0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0}, {5, 3});
    Tensor h = relu(matmul(x, p[0]) + p[1]);
    Tensor logits = matmul(h, p[2]) + p[3];
    return -(onehot * logits.softmax(1).log()).mean() * 3.0;
  });
  fd_case("mlp-wrt-input", {Shape{4, 3}}, [](Session& s, const Ts& p) {
    Tensor w1 = s.array(rand_vec(12, 5), {3, 4}), w2 = s.array(rand_vec(8, 6), {4, 2});
    return matmul(tanh(matmul(p[0], w1)), w2).softmax(1);
  });
  // second derivatives by finite differences of the first
  fd_case("second-softmax-log", {Shape{3, 4}}, [](Session&, const Ts& x) { return grad(x[0].softmax(1).log().sum() * 0.5 + (x[0] * x[0]).sum(), x[0]); });
  fd_case("second-tanh-matmul", {S23, Shape{3, 2}}, [](Session&, const Ts& x) { return grad(matmul(x[0], x[1]).tanh().sum(), x[1]); });
  fd_case("second-exp-sigmoid", {S23}, [](Session&, const Ts& x) { return grad((x[0].exp() * x[0].sigmoid()).sum(), x[0]); });
  fd_case("second-mean-div", {S23, S3}, [](Session&, const Ts& x) { return grad((x[0] / pos(x[1])).mean(), x[1]); });
}

// ---- (b) the operators without a rule: the library's message, and they stay unsupported ----

static void unsupported() {
  static const Shape S23{2, 3};
  // op: the operator named in the refusal; frag: the text the refusal must contain, when it is not "no gradient rule for op type ..."
  struct Case { const char* op; std::function<Tensor(Session&, const Tensor&)> f; const char* frag = nullptr; };
  const char* cast_frag = "Cast to 11 is not differentiated here";
  const char* init_frag = "must be a constant initializer";
  std::vector<Case> cases = {
      {"Sin", [](Session&, const Tensor& x) { return x.sin(); }},
      {"Cos", [](Session&, const Tensor& x) { return x.cos(); }},
      // the mask of where is a comparison, which has no rule: the refusal names it, not Where
      {"Greater", [](Session&, const Tensor& x) { return where(x > 0.0, x, x * 2.0); }},
      {"Cast", [](Session&, const Tensor& x) { return x * (x > 0.0).astype(f64); }, cast_frag},   // a mask made from x: comparisons and casts have no rule
      // master has these rules, but our export writes their shape arguments as nodes, not initializers, and the rules want initializers
      {"Slice", [](Session&, const Tensor& x) { return x.slice(1, 0, 2); }, init_frag},
      {"Expand", [](Session&, const Tensor& x) { return x.broadcast_to({2, 2, 3}); }, init_frag},
      {"Squeeze", [](Session&, const Tensor& x) { return x.expand_dims(0).squeeze(0); }, init_frag},
      {"Unsqueeze", [](Session&, const Tensor& x) { return x.expand_dims(0); }, init_frag},
      {"Cast", [](Session&, const Tensor& x) { return x.astype(f32).astype(f64); }, cast_frag},
  };
  for (const Case& c : cases) {
    Session s;
    s.default_float = f64;
    Tensor x = s.placeholder("x", S23);
    Tensor loss = wsum(s, c.f(s, x));
    const std::string frag = c.frag ? std::string(c.frag) : std::string("no gradient rule for op type '") + c.op + "'";
    CHECK_ERR(grad(loss, x), frag.c_str());
  }
  {  // matmul with a 1-D operand: covered op, refused configuration
    Session s;
    s.default_float = f64;
    Tensor a = s.placeholder("a", {3}), b = s.placeholder("b", {3, 2});
    CHECK_ERR(grad(matmul(a, b).sum(), a), "MatMul with a 1-D operand");
  }
  {  // an unsupported operator off the path of the wrt is not reached
    Session s;
    s.default_float = f64;
    Tensor x = s.placeholder("x", {3}), y = s.placeholder("y", {3});
    Tensor loss = (x * x).sum() + y.sin().sum();
    CHECK(grad(loss, x).shape() == x.shape());
    CHECK_ERR(grad(loss, y), "'Sin'");
  }
}

// ---- (c) exact gradients ----

static V gv(const Tensor& loss, const Tensor& w) { return grad(loss, w).tolist(); }

static void exact() {
  {
    Session s;
    s.default_float = f64;
    Tensor x = s.array({1, 2, 3});
    CHECK_VALS(gv((x * x).sum(), x), V{2, 4, 6});
    CHECK_VALS(gv(x.mean(), x), V(3, 1.0 / 3));
    CHECK_VALS(gv(x.sum() * 5.0, x), V(3, 5.0));
    Tensor loss = (x * 2.0 + x * 3.0).sum();   // a value used twice accumulates
    CHECK_VALS(gv(loss, x), V(3, 5.0));
    CHECK_VALS(gv(x.sum(), x), V(3, 1.0));
    CHECK(grad(x.sum(), x).shape() == x.shape() && grad(x.sum(), x).dtype() == f64);
    CHECK_VALS(gv(x.exp().sum(), x), (V{std::exp(1.0), std::exp(2.0), std::exp(3.0)}));
    CHECK_VALS(gv(x.log().sum(), x), (V{1, 0.5, 1.0 / 3}));
    CHECK_VALS(gv(x.sqrt().sum(), x), (V{0.5, 0.5 / std::sqrt(2.0), 0.5 / std::sqrt(3.0)}));
    CHECK_VALS(gv((1.0 / x).sum(), x), (V{-1, -0.25, -1.0 / 9}));
    CHECK_VALS(gv((x / 2.0).sum(), x), V(3, 0.5));
    CHECK_VALS(gv((10.0 - x).sum(), x), V(3, -1.0));
    double t1 = std::tanh(1.0), sg = 1 / (1 + std::exp(-1.0));
    CHECK_VALS(V{gv(x.tanh().sum(), x).at(0)}, V{1 - t1 * t1});
    CHECK_VALS(V{gv(x.sigmoid().sum(), x).at(0)}, V{sg * (1 - sg)});
  }
  {  // a wrt the loss does not depend on, the loss itself, several wrt at once, an intermediate value
    Session s;
    s.default_float = f64;
    Tensor a = s.array({1, 2}), b = s.array({3, 4, 5}), c = s.array({7});
    Tensor mid = a * a;
    Tensor loss = mid.sum();
    Ts g = grad(loss, Ts{a, b, loss, mid});
    CHECK_VALS(g[0].tolist(), V{2, 4});
    CHECK_VALS(g[1].tolist(), V{0, 0, 0});
    CHECK(g[1].shape() == (Shape{3}) && g[1].dtype() == f64);
    CHECK_VALS(g[2].tolist(), V{1});
    CHECK(g[2].ndim() == 0);
    CHECK_VALS(g[3].tolist(), V{1, 1});
    CHECK_VALS(grad(c.sum(), Ts{c, c})[1].tolist(), V{1});   // the same wrt twice
    CHECK(grad(loss, Ts{}).empty());
    // a wrt that is also upstream of another wrt: the total derivative
    Ts g2 = grad((mid * a).sum(), Ts{a, mid});
    CHECK_VALS(g2[0].tolist(), V{3, 12});   // d/da of a^3, through the intermediate `mid` and directly
    CHECK_VALS(g2[1].tolist(), V{1, 2});
  }
  {  // relu at 0 is 0; Clip passes the gradient only strictly inside its bounds (the old native rule closed the interval)
    Session s;
    s.default_float = f64;
    Tensor z = s.array({-1, 0, 2});
    CHECK_VALS(gv(z.relu().sum(), z), (V{0, 0, 1}));
    Tensor c = s.array({-0.5, 0.0, 0.5, 1.0, 1.5});
    CHECK_VALS(gv(c.clip(0.0, 1.0).sum(), c), (V{0, 0, 1, 0, 0}));
  }
  {  // matmul by hand: y = A B, loss = sum(W * y); dA = W B^T, dB = A^T W
    Session s;
    s.default_float = f64;
    Tensor A = s.array({1, 2, 3, 4, 5, 6}, {2, 3}), B = s.array({7, 8, 9, 10, 11, 12}, {3, 2}), W = s.array({1, 0, 0, 2}, {2, 2});
    Tensor loss = (matmul(A, B) * W).sum();
    CHECK_VALS(gv(loss, A), (V{7 + 0, 9 + 0, 11 + 0, 0 + 2 * 8, 0 + 2 * 10, 0 + 2 * 12}));
    CHECK_VALS(gv(loss, B), (V{1, 2 * 4, 2, 2 * 5, 3, 2 * 6}));
    // a batch dimension of the second operand is summed out of the first
    Tensor M = s.array({1, 2, 3, 4}, {2, 2}), N = s.array({1, 0, 0, 1, 2, 0, 0, 2}, {2, 2, 2});   // identity and 2*identity
    CHECK_VALS(gv(matmul(M, N).sum(), M), (V{3, 3, 3, 3}));
  }
  {  // softmax cross entropy written with Softmax, Log and a one-hot product: d loss / d logits = softmax - onehot
    Session s;
    s.default_float = f64;
    Tensor z = s.array({0.3, -1.2, 2.0}, {1, 3});
    Tensor onehot = s.array({0, 0, 1}, {1, 3});
    Tensor loss = -(onehot * z.softmax(1).log()).sum();
    V e{std::exp(0.3), std::exp(-1.2), std::exp(2.0)};
    double tot = e[0] + e[1] + e[2];
    CHECK_VALS(gv(loss, z), (V{e[0] / tot, e[1] / tot, e[2] / tot - 1}));
    // d softmax(z)[k] / d z : the Jacobian row, through a weighted sum
    Tensor wv = s.array({0, 1, 0}, {1, 3});
    double pk = e[1] / tot;
    CHECK_VALS(gv((z.softmax(1) * wv).sum(), z), (V{-pk * e[0] / tot, pk * (1 - pk), -pk * e[2] / tot}));
  }
  {  // second derivatives: the gradient is an ordinary graph and can be differentiated again
    Session s;
    s.default_float = f64;
    Tensor x = s.array({1, 2, 3});
    Tensor g1 = grad((x * x * x).sum(), x);
    CHECK_VALS(g1.tolist(), (V{3, 12, 27}));
    CHECK_VALS(gv(g1.sum(), x), (V{6, 12, 18}));
    Tensor g2 = grad(x.exp().sum(), x);
    CHECK_VALS(gv(g2.sum(), x), (V{std::exp(1.0), std::exp(2.0), std::exp(3.0)}));
    Tensor y = s.array({0.5, -0.4, 1.5});
    CHECK_VALS(V{gv(grad(y.tanh().sum(), y).sum(), y).at(0)}, V{-2 * std::tanh(0.5) * (1 - std::tanh(0.5) * std::tanh(0.5))});
  }
  {  // a float32 model keeps float32 gradients (onnxsim builds its constants in float32); integer inputs on the side are constants
    Session s;
    Tensor x = s.placeholder("x", {3}), idx = s.placeholder("i", {3}, i32);
    Tensor loss = (x * idx.astype(f32)).sum();
    Tensor gx = grad(loss, x);
    CHECK(gx.dtype() == f32);
    Array r = s.eval(gx, {{"i", arr(i32, {3}, V{1, 2, 3})}});
    CHECK(r.data[2].f == 3);
    Tensor cnt = s.arange(3).sum();   // an integer-valued branch, off the float path
    CHECK(grad((x * x).sum() + cnt.astype(f32) * 0.0, x).dtype() == f32);
  }
}

// ---- the hir level: Identity, a Clip with bounds, the repeated use of one graph ----

static double scalar_of(const Array& a) { return a.data.at(0).as_double(); }
static V vals(const Array& a) { V v; for (const Scalar& s : a.data) v.push_back(s.as_double()); return v; }

static void hir_level() {
  using hir::Attribute;
  {  // Identity; the gradient graph is merged into the same graph, and a second call adds more of it without name clashes
    hir::Graph g;
    int x = g.add_input("x", f64, {3});
    int id = g.add_node("Identity", {x});
    int w = g.add_initializer("", arr(f64, {3}, V{1, 2, 3}));
    int loss = g.add_node("ReduceSum", {g.add_node("Mul", {id, w})}, {Attribute::Int("keepdims", 0)});
    int d = hir::gradients_via_onnxsim(g, loss, {x})[0];
    CHECK(g.value(d).dtype == f64 && g.value(d).shape == (Shape{3}));
    size_t nodes = g.nodes().size();
    int d2 = hir::gradients_via_onnxsim(g, loss, {x})[0];
    CHECK(g.nodes().size() > nodes && d2 != d);
    int dw = hir::gradients_via_onnxsim(g, loss, {w})[0];
    ut::Session u;
    hir::Lowerer low(g, u);
    std::map<std::string, Array> feeds{{"x", arr(f64, {3}, V{.1, .2, .3})}};
    CHECK(near(vals(u.eval(low.get(d), feeds)), V{1, 2, 3}));
    CHECK(near(vals(u.eval(low.get(d2), feeds)), V{1, 2, 3}));
    CHECK(near(vals(u.eval(low.get(dw), feeds)), V{.1, .2, .3}));
    for (size_t k = 0; k < g.num_values(); k++) CHECK(g.find_value(g.value(static_cast<int>(k)).name) == static_cast<int>(k));
  }
  {  // Clip: the bounds get a zero gradient (onnxsim does not differentiate them), x passes strictly inside
    hir::Graph g;
    int x = g.add_input("x", f64, {5}), lo = g.add_input("lo", f64, {}), hi = g.add_input("hi", f64, {});
    int w = g.add_initializer("", arr(f64, {5}, V{1, 2, 3, 4, 5}));
    int cl = g.add_node("Clip", {x, lo, hi});
    int loss = g.add_node("ReduceSum", {g.add_node("Mul", {cl, w})}, {Attribute::Int("keepdims", 0)});
    std::vector<int> d = hir::gradients_via_onnxsim(g, loss, {x, lo, hi});
    ut::Session u;
    hir::Lowerer low(g, u);
    std::map<std::string, Array> feeds{{"x", arr(f64, {5}, V{-2, -1, 0, 1, 2})}, {"lo", arr(f64, {}, V{-1})}, {"hi", arr(f64, {}, V{1})}};
    CHECK(near(vals(u.eval(low.get(d[0]), feeds)), V{0, 0, 3, 0, 0}));   // the bounds themselves get no gradient
    CHECK(scalar_of(u.eval(low.get(d[1]), feeds)) == 0 && scalar_of(u.eval(low.get(d[2]), feeds)) == 0);
    CHECK(g.value(d[1]).shape.empty() && g.value(d[2]).dtype == f64);
  }
  {  // a wrt that is an input the loss does not use, and a scalar loss that is an input
    hir::Graph g;
    int x = g.add_input("x", f64, {2}), unused = g.add_input("u", f64, {2, 2});
    int loss = g.add_node("ReduceSum", {x}, {Attribute::Int("keepdims", 0)});
    std::vector<int> d = hir::gradients_via_onnxsim(g, loss, {x, unused});
    ut::Session u;
    hir::Lowerer low(g, u);
    std::map<std::string, Array> feeds{{"x", arr(f64, {2}, V{1, 2})}, {"u", arr(f64, {2, 2}, V(4, 1.0))}};
    CHECK(near(vals(u.eval(low.get(d[0]), feeds)), V{1, 1}) && near(vals(u.eval(low.get(d[1]), feeds)), V(4, 0.0)));
    hir::Graph g2;
    int s = g2.add_input("s", f64, {});
    int ds = hir::gradients_via_onnxsim(g2, s, {s})[0];   // the loss is an input
    ut::Session u2;
    hir::Lowerer low2(g2, u2);
    CHECK(scalar_of(u2.eval(low2.get(ds), {{"s", arr(f64, {}, V{3})}})) == 1);
  }
}

// ---- (d) errors that need no backend ----

static void errors() {
  Session s;
  s.default_float = f64;
  Tensor x = s.placeholder("x", {2, 3}), y = s.placeholder("y", {3});
  CHECK_ERR(grad(x * 2.0, x), "empty shape");                 // not a scalar
  CHECK_ERR(grad(x.sum(0), x), "empty shape");
  CHECK_ERR(grad(x.sum(1, true).sum(0, true), x), "empty shape");   // shape (1, 1)
  Tensor n = s.placeholder("n", {3}, i32);
  CHECK_ERR(grad(n.sum(), n), "float");                       // an integer loss
  CHECK_ERR(grad(n.sum(), x), "float");
  CHECK_ERR(grad(x.sum() > 0, x), "float");                   // a bool loss
  CHECK_ERR(grad(x.sum(), n), "cannot differentiate");        // an integer wrt
  CHECK_ERR(grad(x.sum(), s.arange(3)), "cannot differentiate");
  CHECK_ERR(grad(Tensor(), x), "");
  Session other;
  CHECK_ERR(grad(x.sum(), other.placeholder("z", {2})), "");
  hir::Graph g;
  int a = g.add_input("a", f64, {2});
  int l = g.add_node("ReduceSum", {a}, {hir::Attribute::Int("keepdims", 0)});
  CHECK_ERR(hir::gradients_via_onnxsim(g, 99, {a}), "no value");
  CHECK_ERR(hir::gradients_via_onnxsim(g, l, {99}), "no value");
  CHECK_ERR(hir::gradients_via_onnxsim(g, a, {a}), "empty shape");   // the loss has shape (2)
  CHECK(hir::gradients_via_onnxsim(g, l, {}).empty());
  // a wrt outside the loss' sub-graph needs no backend: its gradient is zero
  Tensor outside = s.placeholder("outside", {4});
  Tensor gz = grad(y.sum(), outside);
  CHECK(gz.shape() == outside.shape() && gz.dtype() == f64);
  CHECK_VALS(s.eval(gz, {{"y", arr(f64, {3}, V(3, 1.0))}, {"outside", arr(f64, {4}, V(4, 2.0))}}).data.size() == 4 ? V{1} : V{0}, V{1});
}

// With neither the library nor python, the message says what is missing and how to get it. Run in a child process with the
// environment set so that the choice (made once per process) sees nothing.
static int missing_child(const char* mode) {
  Session s;
  s.default_float = f64;
  Tensor x = s.placeholder("x", {2});
  std::string msg;
  try {
    grad((x * x).sum(), x);
  } catch (const Error& e) {
    msg = e.what();
  }
  std::printf("%s\n", msg.c_str());
  bool ok = msg.find("onnxsim is not available") != std::string::npos && msg.find("docs/notes/uop-autodiff.md") != std::string::npos;
  if (std::strcmp(mode, "python") == 0) ok = ok && msg.find("python is not available") != std::string::npos;
  if (std::strcmp(mode, "library") == 0) ok = ok && msg.find("/nonexistent/libnfconnxsim.so") != std::string::npos && msg.find("scripts/setup-onnxsim.sh") != std::string::npos;
  if (std::strcmp(mode, "scriptless") == 0) ok = ok && msg.find("scripts/onnx_grad.py not found") != std::string::npos;
  return ok ? 0 : 1;
}
static void missing_backends(const char* self) {
  struct Run { const char* mode; const char* env; };
  const Run runs[] = {
      {"python", "NFCUOP_ONNXSIM_BACKEND=python NFCUOP_PYTHON=/nonexistent/python3"},
      {"library", "NFCUOP_ONNXSIM_BACKEND=library NFCUOP_ONNXSIM=/nonexistent/libnfconnxsim.so"},
      {"scriptless", "NFCUOP_ONNXSIM_BACKEND=python NFCUOP_ONNX_GRAD=/nonexistent/onnx_grad.py"},
  };
  for (const Run& r : runs) {
    std::string cmd = std::string("NFCUOP_TEST_MISSING=") + r.mode + " " + r.env + " '" + self + "' > /dev/null 2>&1";
    int rc = std::system(cmd.c_str());
    CHECK(rc == 0);
    if (rc != 0) std::printf("  missing-backend run %s failed (%s)\n", r.mode, cmd.c_str());
  }
}

// ---- (e) the C backend equals the interpreter bit for bit ----

static bool same_bits(const Array& a, const Array& b) {
  if (a.dtype != b.dtype || a.shape != b.shape || a.data.size() != b.data.size()) return false;
  for (size_t k = 0; k < a.data.size(); k++) {
    if (is_float(a.dtype)) {
      if (std::memcmp(&a.data[k].f, &b.data[k].f, sizeof(double)) != 0) return false;
    } else if (a.data[k].i != b.data[k].i) {
      return false;
    }
  }
  return true;
}

static int c_compared = 0;
static void c_vs_interpreter(DType dt) {
  Session s;
  s.default_float = dt;
  Tensor x = s.placeholder("x", {4, 3}), w1 = s.placeholder("w1", {3, 5}), b1 = s.placeholder("b1", {5}), w2 = s.placeholder("w2", {5, 3}), b2 = s.placeholder("b2", {3});
  Tensor onehot = s.array({1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0}, {4, 3});
  Tensor loss1 = -(onehot * (matmul(relu(matmul(x, w1) + b1), w2) + b2).softmax(1).log()).sum() / 4.0;
  Tensor t = s.placeholder("t", {2, 3, 4});
  Tensor loss2 = (matmul(t, t.transpose({0, 2, 1})).softmax(2).sum(2, true) * (t * t + 0.5).sqrt().mean(2, true)).sum() + t.reshape({6, 4}).tanh().sum() +
                 (t.sigmoid() / (t * t + 1.0)).mean() + t.clip(-0.5, 0.5).sum() + (t.exp() - (-t)).mean(1).sum();
  std::map<std::string, Array> feeds{{"x", arr(dt, {4, 3}, rand_vec(12, 1))}, {"w1", arr(dt, {3, 5}, rand_vec(15, 2))}, {"b1", arr(dt, {5}, rand_vec(5, 3))},
                                      {"w2", arr(dt, {5, 3}, rand_vec(15, 4))}, {"b2", arr(dt, {3}, rand_vec(3, 5))}, {"t", arr(dt, {2, 3, 4}, rand_vec(24, 6))}};
  Ts outs{loss1, loss2};
  for (const Tensor& g : grad(loss1, Ts{w1, b1, w2, b2, x})) outs.push_back(g);
  for (const Tensor& g : grad(loss2, Ts{t})) outs.push_back(g);
  s.backend = ut::Session::Backend::Interpreter;
  std::vector<Array> ref = s.eval_all(outs, feeds);
  s.backend = ut::Session::Backend::C;
  std::vector<Array> got = s.eval_all(outs, feeds);
  bool ok = ref.size() == got.size();
  for (size_t k = 0; ok && k < ref.size(); k++) ok = same_bits(ref[k], got[k]), c_compared++;
  CHECK(ok);
  CHECK(std::fabs(ref[2].data[0].as_double()) + std::fabs(ref[7].data[3].as_double()) > 0);   // not trivially zero
}

// ---- (f) models with gradient outputs for onnx_check.py ----

static void write(const std::string& path, const std::string& bytes) {
  std::ofstream f(path, std::ios::binary);
  f.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}
static std::string jarr(const Array& a) {
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
}
static void emit(const std::string& dir, const std::string& nm, Session& s, const std::vector<std::pair<std::string, Tensor>>& outs, const std::map<std::string, Array>& feeds) {
  write(dir + "/" + nm + ".onnx", s.to_onnx(outs));
  std::string j = "{\"inputs\":{";
  bool first = true;
  for (const auto& f : feeds) { j += (first ? "" : ",") + ("\"" + f.first + "\":" + jarr(f.second)); first = false; }
  j += "},\"outputs\":{";
  first = true;
  for (const auto& o : outs) { j += (first ? "" : ",") + ("\"" + o.first + "\":" + jarr(s.eval(o.second, feeds))); first = false; }
  write(dir + "/" + nm + ".json", j + "}}");
}

static size_t graph_nodes_mlp = 0, graph_nodes_mlp_forward = 0;
static void models(const std::string& dir) {
  {  // a 2-layer MLP with softmax cross entropy: the loss and the gradient of every parameter and of the input
    Session s;
    Tensor x = s.placeholder("x", {4, 3}), y = s.placeholder("y", {4, 3});
    Tensor w1 = s.placeholder("w1", {3, 5}), b1 = s.placeholder("b1", {5}), w2 = s.placeholder("w2", {5, 3}), b2 = s.placeholder("b2", {3});
    Tensor loss = -(y * (matmul(relu(matmul(x, w1) + b1), w2) + b2).softmax(1).log()).sum() / 4.0;
    size_t before = s.graph().nodes().size();
    graph_nodes_mlp_forward = before;
    Ts g = grad(loss, Ts{w1, b1, w2, b2, x});
    graph_nodes_mlp = s.graph().nodes().size() - before;
    CHECK(g.size() == 5);
    if (dir.empty()) return;
    std::map<std::string, Array> feeds{{"x", arr(f32, {4, 3}, rand_vec(12, 11))}, {"y", arr(f32, {4, 3}, V{1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0})}, {"w1", arr(f32, {3, 5}, rand_vec(15, 12))},
                                        {"b1", arr(f32, {5}, rand_vec(5, 13))}, {"w2", arr(f32, {5, 3}, rand_vec(15, 14))}, {"b2", arr(f32, {3}, rand_vec(3, 15))}};
    emit(dir, "grad_mlp", s, {{"loss", loss}, {"dw1", g[0]}, {"db1", g[1]}, {"dw2", g[2]}, {"db2", g[3]}, {"dx", g[4]}}, feeds);
  }
  if (dir.empty()) return;
  {  // elementwise, reductions, clip, broadcasting
    Session s;
    Tensor x = s.placeholder("x", {3, 6}), b = s.placeholder("b", {6});
    Tensor loss = x.exp().sum() + x.tanh().mean() + x.sigmoid().sum() + (x * b).relu().sum() + x.clip(-0.5, 0.5).sum() + (x * x + 1.0).sqrt().log().sum() +
                  (x / (x * x + 1.0)).sum() + x.softmax(1).square().sum() + (x - x.mean(1, true)).square().mean() + (b * b).sum(0);
    Ts g = grad(loss, Ts{x, b});
    emit(dir, "grad_ops", s, {{"loss", loss}, {"dx", g[0]}, {"db", g[1]}}, {{"x", arr(f32, {3, 6}, rand_vec(18, 21))}, {"b", arr(f32, {6}, rand_vec(6, 22))}});
  }
  {  // batched matmul with broadcasting, layer normalization
    Session s;
    Tensor t = s.placeholder("t", {2, 3, 4}), w = s.placeholder("w", {4, 2}), u = s.placeholder("u", {2, 1, 3, 4}), k = s.placeholder("k", {5, 4, 2});
    Tensor ln = (t - t.mean(2, true)) / ((t - t.mean(2, true)).square().mean(2, true) + 1e-3).sqrt();
    Tensor loss = matmul(t, w).tanh().sum() + matmul(u, k).tanh().sum() + (ln * t).sum();
    Ts g = grad(loss, Ts{t, w, u, k});
    emit(dir, "grad_matmul", s, {{"loss", loss}, {"dt", g[0]}, {"dw", g[1]}, {"du", g[2]}, {"dk", g[3]}},
         {{"t", arr(f32, {2, 3, 4}, rand_vec(24, 31))}, {"w", arr(f32, {4, 2}, rand_vec(8, 32))},
          {"u", arr(f32, {2, 1, 3, 4}, rand_vec(24, 34))}, {"k", arr(f32, {5, 4, 2}, rand_vec(40, 35))}});
  }
  {  // a second derivative, and float64
    Session s;
    s.default_float = f64;
    Tensor x = s.placeholder("x", {5});
    Tensor loss = (x * x * x).sum() + x.tanh().sum();
    Tensor g1 = grad(loss, x);
    Tensor g2 = grad(g1.sum(), x);
    emit(dir, "grad_second", s, {{"loss", loss}, {"g1", g1}, {"g2", g2}}, {{"x", arr(f64, {5}, rand_vec(5, 41))}});
  }
}

int main(int argc, char** argv) {
  if (const char* m = std::getenv("NFCUOP_TEST_MISSING")) return missing_child(m);
  errors();
  std::string info;
  if (!hir::onnxsim_available(&info)) {
    std::printf("SKIP test_grad: onnxsim is not available (%s)\n", info.c_str());
    if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
    std::printf("%d checks passed (argument checks only)\n", checks);
    return 0;
  }
  std::printf("onnxsim through %s\n", info.c_str());
  finite_differences();
  unsupported();
  exact();
  hir_level();
  c_vs_interpreter(f64);
  c_vs_interpreter(f32);
  models(argc > 1 ? argv[1] : "");
  missing_backends(argv[0]);
  std::printf("%d finite-difference cases (%d elements), max relative error %.2e; %d gradient arrays equal bit for bit between the C backend and the interpreter; the MLP (%zu forward nodes) gradient adds %zu nodes\n",
              fd_cases, fd_elements, max_fd_err, c_compared, graph_nodes_mlp_forward, graph_nodes_mlp);
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
