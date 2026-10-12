// nfcuop C rendering (nfcuop_cgen.hpp): what gets fused, and that the generated C computes exactly what the interpreter
// computes: on hand-written graphs, on random scalar, integer-tensor and float-tensor graphs (each batch is one compiled
// program), on every dtype, and through the numpy-like API. Compiles C with $NFCUOP_CC or cc.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <limits>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_np.hpp"

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

static const DType f32 = DType::Float32, f64 = DType::Float64, i32 = DType::Int32, i64 = DType::Int64, bl = DType::Bool;

// equal bit for bit, except that every NaN equals every NaN
static bool same(const Scalar& a, const Scalar& b) {
  if (is_float(a.dtype) && is_float(b.dtype) && std::isnan(a.f) && std::isnan(b.f)) return a.dtype == b.dtype;
  return a == b;
}
static bool same(const Array& a, const Array& b) {
  if (a.dtype != b.dtype || a.shape != b.shape || a.data.size() != b.data.size()) return false;
  for (size_t k = 0; k < a.data.size(); k++) if (!same(a.data[k], b.data[k])) return false;
  return true;
}

using Env = std::map<std::string, Array>;

// The program for `roots`, compiled once, run on every env, compared with the interpreter.
static void compare_run(const std::vector<const UOp*>& roots, const std::vector<Env>& envs, const char* label) {
  CProgram p = render_c(roots);
  std::shared_ptr<CModule> m = CModule::compile(p);
  int bad = 0;
  for (const Env& env : envs) {
    std::vector<Array> got = m->run(env);
    for (size_t k = 0; k < roots.size(); k++) {
      Array want = evaluate_array(roots[k], env);
      checks++;
      if (!same(want, got[k])) {
        if (bad++ < 3) std::printf("FAIL %s: output %zu differs\n%s", label, k, dump(roots[k]).c_str());
        failed++;
      }
    }
  }
}

static void structure() {
  Graph g;
  const UOp* x = g.var("x", f32, {2, 3});
  const UOp* y = g.var("y", f32, {2, 3});
  auto prog = [&](std::vector<const UOp*> u) { return render_c(u); };
  // elementwise chains and movement ops fuse into one loop nest with no temporary
  CProgram p = prog({g.mul(g.add(x, y), g.neg(x))});
  CHECK(p.kernels == 1 && p.temporaries == 0 && p.inputs.size() == 2 && p.inputs[0].name == "x" && p.inputs[1].name == "y");
  CHECK(p.source.find("malloc(") == std::string::npos && p.source.find("nfcuop_run") != std::string::npos);
  p = prog({g.add(g.permute(x, {1, 0}), g.reshape(g.expand(g.reshape(g.var("z", f32, {3}), {3, 1}), {3, 2}), {3, 2}))});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  p = prog({g.pad(g.shrink(g.flip(x, {1}), {0, 1}, {2, 3}), {1, 0}, {0, 2})});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  // a reduction is a loop nest of its own, with its producer fused inside it
  p = prog({g.reduce_sum(g.mul(x, y), {1})});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  // softmax: max, shifted exp (used twice), sum, divide
  const UOp* mx = g.expand(g.reduce_max(x, {1}), {2, 3});
  const UOp* e = g.exp2(g.sub(x, mx));
  const UOp* sm = g.fdiv(e, g.expand(g.reduce_sum(e, {1}), {2, 3}));
  p = prog({sm});
  CHECK(p.kernels == 4 && p.temporaries == 3);
  // a node used twice is computed once if it is real work, and not at all if it is only an index change
  const UOp* s = g.add(x, y);
  p = prog({g.mul(s, s)});
  CHECK(p.kernels == 2 && p.temporaries == 1);
  const UOp* t = g.permute(x, {1, 0});
  p = prog({g.mul(t, t)});
  CHECK(p.kernels == 1 && p.temporaries == 0);
  // sharing cannot blow the code up: 40 levels of a + a are 40 loop nests, not 2^40 terms
  const UOp* a = x;
  for (int k = 0; k < 40; k++) a = g.add(a, a);
  p = prog({a});
  CHECK(p.kernels == 40 && p.source.size() < 200000);
  // several outputs share their common subgraph; an output given twice, and outputs that are leaves
  p = prog({s, g.mul(s, x)});
  CHECK(p.kernels == 2 && p.temporaries == 0 && p.outputs.size() == 2);
  p = prog({s, s});
  CHECK(p.kernels == 1 && p.outputs.size() == 2);
  p = prog({x, g.fconst(f32, 2.5, {2}), g.fconst(f32, 1.5)});
  CHECK(p.kernels == 3);
  compare_run({s, s, x, g.fconst(f32, 2.5, {2}), g.fconst(f32, 1.5), g.mul(s, x)},
              {Env{{"x", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}, {"y", Array::from_doubles(f32, {2, 3}, {6, 5, 4, 3, 2, 1})}}}, "outputs");
  CHECK_THROWS(prog({}));
  CHECK_THROWS(prog({g.var("x", f32, {3}), x}));  // one name, two shapes
  // run() checks its inputs
  auto m = CModule::compile(prog({s}));
  CHECK_THROWS(m->run({}));
  CHECK_THROWS(m->run({{"x", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}}));
  CHECK_THROWS(m->run({{"x", Array::from_doubles(f32, {3, 2}, {1, 2, 3, 4, 5, 6})}, {"y", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}}));
  CHECK_THROWS(m->run({{"x", Array::from_doubles(f64, {2, 3}, {1, 2, 3, 4, 5, 6})}, {"y", Array::from_doubles(f32, {2, 3}, {1, 2, 3, 4, 5, 6})}}));
  // compile errors carry the compiler's words
  CProgram broken = p;
  broken.source = "int nfcuop_run( this is not C";
  try { CModule::compile(broken); CHECK(false); } catch (const Error& er) { CHECK(std::string(er.what()).find("error") != std::string::npos); }
  CHECK_THROWS(CModule::compile(p, "no-such-compiler-nfcuop"));
}

// ---- random graphs ----

struct Rng {
  unsigned long long seed;
  unsigned operator()(unsigned n) { seed = seed * 6364136223846793005ull + 1442695040888963407ull; return static_cast<unsigned>((seed >> 33) % n); }
};

static void random_scalars() {
  Graph g;
  Rng rnd{12345};
  const UOp* x = g.var("x", i32);
  const UOp* y = g.var("y", i32);
  struct Gen {
    Graph& g; Rng& rnd; const UOp *x, *y;
    const UOp* leaf() {
      switch (rnd(7)) { case 0: return x; case 1: return y; default: return g.iconst(i32, static_cast<int>(rnd(7)) - 2); }
    }
    const UOp* boolean(int d) {
      if (d <= 0 || rnd(5) == 0) return rnd(2) ? g.cmplt(leaf(), leaf()) : g.cmpne(leaf(), leaf());
      switch (rnd(4)) {
        case 0: return g.band(boolean(d - 1), boolean(d - 1));
        case 1: return g.bor(boolean(d - 1), boolean(d - 1));
        case 2: return g.bxor(boolean(d - 1), boolean(d - 1));
        default: return g.cmplt(num(d - 1), num(d - 1));
      }
    }
    const UOp* num(int d) {
      if (d <= 0 || rnd(6) == 0) return leaf();
      switch (rnd(12)) {
        case 0: return g.add(num(d - 1), num(d - 1));
        case 1: return g.sub(num(d - 1), num(d - 1));
        case 2: return g.mul(num(d - 1), num(d - 1));
        case 3: return g.max(num(d - 1), num(d - 1));
        case 4: return g.band(num(d - 1), num(d - 1));
        case 5: return g.bor(num(d - 1), num(d - 1));
        case 6: return g.bxor(num(d - 1), num(d - 1));
        case 7: return g.neg(num(d - 1));
        case 8: return g.where(boolean(d - 1), num(d - 1), num(d - 1));
        case 9: return g.idiv(num(d - 1), g.iconst(i32, 1 + rnd(3)));
        case 10: return g.mod(num(d - 1), g.iconst(i32, 1 + rnd(3)));
        default: return g.cast(g.cast(num(d - 1), f32), i32);
      }
    }
  } gen{g, rnd, x, y};
  std::vector<const UOp*> roots;
  for (int k = 0; k < 250; k++) roots.push_back(gen.num(5));
  std::vector<Env> envs;
  for (int vx : {-3, -1, 0, 1, 2, 7, 2147483647})
    for (int vy : {-2, 0, 1, 5, -2147483647 - 1})
      envs.push_back(Env{{"x", Array(i32, {}, {Scalar::from_int(i32, vx)})}, {"y", Array(i32, {}, {Scalar::from_int(i32, vy)})}});
  compare_run(roots, envs, "random scalars");
}

static void random_int_tensors() {
  Graph g;
  Rng rnd{777};
  const UOp* a = g.var("a", i32, {2, 3, 2});
  std::vector<const UOp*> roots;
  for (int t = 0; t < 150; t++) {
    const UOp* e = a;
    for (int step = 0; step < 6; step++) {
      switch (rnd(12)) {
        case 0: {
          size_t r = e->shape.size();
          Shape perm;
          for (size_t k = 0; k < r; k++) perm.push_back(static_cast<int64_t>(rnd(2) ? (k + 1) % r : r - 1 - k));
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
        case 8: { Shape r = e->shape, lo(r.size(), 0), hi = r; size_t ax = rnd(static_cast<unsigned>(r.size())); if (r[ax] > 1) lo[ax] = 1; e = g.shrink(e, lo, hi); break; }
        case 9: { Shape z(e->shape.size(), 0), a2 = z; a2[rnd(static_cast<unsigned>(z.size()))] = static_cast<int64_t>(rnd(2) + 1); e = g.pad(e, z, a2); break; }
        case 10: { Shape ax{static_cast<int64_t>(rnd(static_cast<unsigned>(e->shape.size())))}; e = g.flip(e, ax); break; }
        default: e = g.where(g.cmplt(e, g.iconst(i32, 2, e->shape)), e, g.neg(e)); break;
      }
    }
    roots.push_back(e);
  }
  std::vector<Env> envs;
  for (int t = 0; t < 20; t++) {
    Array arr;
    arr.dtype = i32;
    arr.shape = {2, 3, 2};
    for (int k = 0; k < 12; k++) arr.data.push_back(Scalar::from_int(i32, static_cast<int>(rnd(9)) - 4));
    envs.push_back(Env{{"a", arr}});
  }
  compare_run(roots, envs, "random int tensors");
  // the same graphs after symbolic(): the rewritten graph renders and agrees too
  std::vector<const UOp*> simplified;
  for (const UOp* r : roots) simplified.push_back(graph_rewrite(g, symbolic(), r));
  compare_run(simplified, envs, "random int tensors, simplified");
}

static void random_float_tensors() {
  Graph g;
  Rng rnd{4242};
  const UOp* f = g.var("f", f32, {2, 3});
  const UOp* h = g.var("h", f32, {2, 3});
  struct Gen {
    Graph& g; Rng& rnd; const UOp *f, *h;
    const UOp* leaf() {
      static const double c[] = {0.5, -1, 2, 0, 3.25, -0.0, 1e30};
      switch (rnd(5)) { case 0: return f; case 1: return h; default: return g.fconst(f32, c[rnd(7)], {2, 3}); }
    }
    const UOp* num(int d) {
      if (d <= 0 || rnd(6) == 0) return leaf();
      switch (rnd(15)) {
        case 0: return g.add(num(d - 1), num(d - 1));
        case 1: return g.sub(num(d - 1), num(d - 1));
        case 2: return g.mul(num(d - 1), num(d - 1));
        case 3: return g.fdiv(num(d - 1), num(d - 1));
        case 4: return g.max(num(d - 1), num(d - 1));
        case 5: return g.neg(num(d - 1));
        case 6: return g.sqrt(num(d - 1));
        case 7: return g.exp2(num(d - 1));
        case 8: return g.log2(num(d - 1));
        case 9: return g.sin(num(d - 1));
        case 10: { const UOp* a = num(d - 1); const UOp* b = num(d - 1); return g.where(g.cmplt(a, b), a, b); }
        case 11: return g.cast(g.add(g.cast(num(d - 1), f64), g.cast(num(d - 1), f64)), f32);
        case 12: {  // a reduction over one axis, broadcast back
          const UOp* a = num(d - 1);
          int64_t ax = static_cast<int64_t>(rnd(2));
          const UOp* r = rnd(2) ? g.reduce_sum(a, {ax}) : g.reduce_max(a, {ax});
          return g.expand(r, {2, 3});
        }
        case 13: return g.flip(num(d - 1), {static_cast<int64_t>(rnd(2))});
        default: return g.permute(g.permute(num(d - 1), {1, 0}), {1, 0});
      }
    }
  } gen{g, rnd, f, h};
  std::vector<const UOp*> roots;
  for (int k = 0; k < 150; k++) roots.push_back(gen.num(5));
  std::vector<Env> envs;
  const double special[] = {0.0, -0.0, 1e30, -1e30, 1e-30, 3.5, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()};
  for (int t = 0; t < 14; t++) {
    Env env;
    for (const char* n : {"f", "h"}) {
      Array arr;
      arr.dtype = f32;
      arr.shape = {2, 3};
      for (int k = 0; k < 6; k++)
        arr.data.push_back(Scalar::from_double(f32, t >= 10 && rnd(3) == 0 ? special[rnd(8)] : (static_cast<double>(rnd(2001)) - 1000) / 250.0));
      env[n] = arr;
    }
    envs.push_back(env);
  }
  compare_run(roots, envs, "random float tensors");
}

static void dtypes() {
  Graph g;
  // 64-bit integers: wrap, extremes, casts
  const UOp* p = g.var("p", i64);
  const UOp* q = g.var("q", i64);
  const UOp* big = g.iconst(i64, INT64_MAX);
  const UOp* mn = g.iconst(i64, INT64_MIN);
  std::vector<const UOp*> r = {
      g.add(p, big), g.mul(p, q), g.sub(mn, p), g.neg(mn), g.idiv(mn, g.iconst(i64, -1)), g.mod(mn, g.iconst(i64, -1)),
      g.idiv(p, g.iconst(i64, 7)), g.mod(p, g.iconst(i64, -7)), g.max(p, q), g.cast(p, i32), g.cast(g.cast(p, i32), i64),
      g.cast(p, f32), g.cast(p, f64), g.cast(p, bl), g.band(p, q), g.bor(p, q), g.bxor(p, q), g.cmplt(p, q), g.cmpne(p, q),
      g.where(g.cmplt(p, q), p, q), mn, big, g.reduce_sum(g.expand(g.reshape(p, {1}), {4}), {0}), g.reduce_max(g.expand(g.reshape(q, {1}), {3}), {0})};
  std::vector<Env> envs;
  for (int64_t vp : {int64_t(0), int64_t(1), int64_t(-1), INT64_MAX, INT64_MIN, int64_t(1) << 40, int64_t(-12345678901LL)})
    for (int64_t vq : {int64_t(3), int64_t(-3), INT64_MAX, INT64_MIN})
      envs.push_back(Env{{"p", Array(i64, {}, {Scalar::from_int(i64, vp)})}, {"q", Array(i64, {}, {Scalar::from_int(i64, vq)})}});
  compare_run(r, envs, "int64");
  // float64
  const UOp* u = g.var("u", f64);
  const UOp* v = g.var("v", f64);
  std::vector<const UOp*> d = {
      g.add(u, v), g.sub(u, v), g.mul(u, v), g.fdiv(u, v), g.max(u, v), g.neg(u), g.sqrt(u), g.exp2(u), g.log2(u), g.sin(u),
      g.cast(u, f32), g.cast(u, i32), g.cast(u, i64), g.cast(u, bl), g.cmplt(u, v), g.cmpne(u, v), g.fconst(f64, 0.1), g.fconst(f64, -0.0),
      g.fconst(f64, std::numeric_limits<double>::infinity()), g.fconst(f64, -std::numeric_limits<double>::infinity()),
      g.fconst(f64, std::numeric_limits<double>::quiet_NaN()), g.fconst(f32, 0.1), g.fconst(f32, std::numeric_limits<double>::max())};
  envs.clear();
  for (double vu : {0.0, -0.0, 1.0, -2.5, 3e10, -3e10, 1e19, -1e19, 2147483647.5, 0.1, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()})
    for (double vv : {1.0, -3.0, 0.0, 1e300})
      envs.push_back(Env{{"u", Array(f64, {}, {Scalar::from_double(f64, vu)})}, {"v", Array(f64, {}, {Scalar::from_double(f64, vv)})}});
  compare_run(d, envs, "float64");
  // bool, and ints around the 32-bit edge
  const UOp* b1 = g.var("b1", bl);
  const UOp* b2 = g.var("b2", bl);
  const UOp* k = g.var("k", i32);
  std::vector<const UOp*> b = {
      g.band(b1, b2), g.bor(b1, b2), g.bxor(b1, b2), g.cmpne(b1, b2), g.cmplt(b1, b2), g.where(b1, k, g.neg(k)), g.cast(b1, i32), g.cast(b1, f32),
      g.cast(b1, i64), g.cast(k, bl), g.cast(k, i64), g.cast(g.cast(k, f32), i32), g.idiv(k, g.iconst(i32, -1)), g.mod(k, g.iconst(i32, -1)),
      g.max(k, g.iconst(i32, INT32_MIN)), g.iconst(i32, INT32_MIN), g.iconst(i32, INT32_MAX), g.add(k, g.iconst(i32, INT32_MAX))};
  envs.clear();
  for (int vb1 : {0, 1}) for (int vb2 : {0, 1}) for (int vk : {0, 1, -1, INT32_MAX, INT32_MIN, 100000})
    envs.push_back(Env{{"b1", Array(bl, {}, {Scalar::from_int(bl, vb1)})}, {"b2", Array(bl, {}, {Scalar::from_int(bl, vb2)})}, {"k", Array(i32, {}, {Scalar::from_int(i32, vk)})}});
  compare_run(b, envs, "bool and int32");
  // division by zero: the interpreter throws, the C code gives 0
  const UOp* z = g.var("z", i32);
  const UOp* dz = g.idiv(g.iconst(i32, 7), z);
  const UOp* mz = g.mod(g.iconst(i32, 7), z);
  Env zero{{"z", Array(i32, {}, {Scalar::from_int(i32, 0)})}};
  CHECK_THROWS(evaluate_array(dz, zero));
  std::vector<Array> out = CModule::compile(render_c({dz, mz}))->run(zero);
  CHECK(out[0].data[0] == Scalar::from_int(i32, 0) && out[1].data[0] == Scalar::from_int(i32, 0));
}

// ---- through the numpy-like API ----

static void numpy_api() {
  using namespace nfcuop::np;
  Session np;
  Tensor x = np.placeholder("x", {2, 3});
  Tensor w = np.array({0.1, -0.2, 0.3, 0.4, 0.5, -0.6, 0.7, 0.8, -0.9, 1.0, 1.1, 1.2}, {3, 4});
  Tensor a = np.array({7, -7, 3, -3, 2, -5}, {2, 3}, i32);
  Tensor m = np.arange(24).reshape({2, 3, 4});
  std::vector<std::pair<std::string, Tensor>> cases = {
      {"mlp", softmax(relu(matmul(x, w) + 0.1))}, {"logsoftmax", (x * 3).log_softmax()}, {"var", x.var(Axes{1})}, {"std", x.stddev()},
      {"clip", x.clip(-1, 2)}, {"where", where(x > 0, x, -x * 2)}, {"slice", m.slice(2, None, None, 2).slice(1, 1, None)},
      {"neg_step", m.slice(2, None, None, -2)}, {"concat", concatenate({x, x * 2, x - 1}, 1)}, {"stack", stack({x, x + 1}, 2)},
      {"floor_divide", floor_divide(a, np.array({2, -2, 3}, i32))}, {"remainder", a % 3}, {"imatmul", matmul(a, a.T())},
      {"minmax", x.max(1) - x.min(0).sum()}, {"tanh", x.tanh() + x.sigmoid() + x.exp() * x.cos()}, {"mean", m.mean(Axes{0, 2})},
      {"cast", (x * 100).astype(i32).astype(DType::Float64)}, {"batched", matmul(m, np.ones({4, 2}))}};
  Env feeds{{"x", Array::from_doubles(f32, {2, 3}, {1, -2, 3, 0.5, -0.25, 6})}};
  std::vector<Tensor> ts;
  for (const auto& c : cases) ts.push_back(c.second);
  np.backend = ut::Session::Backend::Interpreter;
  std::vector<Array> want = np.eval_all(ts, feeds);
  np.backend = ut::Session::Backend::C;
  std::vector<Array> got = np.eval_all(ts, feeds);   // one program for all of them
  CHECK(np.uop_session().last_program() != nullptr && np.uop_session().last_program()->outputs.size() == cases.size());
  for (size_t k = 0; k < cases.size(); k++) {
    checks++;
    if (!same(want[k], got[k])) { failed++; std::printf("FAIL numpy api %s differs between the interpreter and C\n", cases[k].first.c_str()); }
  }
  CHECK(np.eval(cases[0].second, feeds).data[0] == want[0].data[0]);   // single tensor, C backend, cached module
  CHECK(cases[6].second.str().size() > 0);                               // str() works through the C backend
  // an eval with the optimizer off renders the unsimplified graph
  np.optimize = false;
  Array raw = np.eval(cases[4].second, feeds);
  np.optimize = true;
  CHECK(same(raw, want[4]));
  // 64-bit defaults
  Session wide;
  wide.default_float = f64;
  wide.default_int = i64;
  Tensor ints = wide.arange(10);
  Tensor fl = wide.linspace(0, 1, 10);
  std::vector<Tensor> t2 = {ints.sum(), (ints / 3).mean(), softmax(fl * 5), matmul(ints.reshape({2, 5}), ints.reshape({5, 2})), fl.var()};
  wide.backend = ut::Session::Backend::Interpreter;
  std::vector<Array> w2 = wide.eval_all(t2);
  wide.backend = ut::Session::Backend::C;
  std::vector<Array> g2 = wide.eval_all(t2);
  for (size_t k = 0; k < t2.size(); k++) CHECK(same(w2[k], g2[k]));
  CHECK(g2[0].dtype == i64 && g2[1].dtype == f64 && g2[0].data[0].i == 45);
}

int main(int argc, char** argv) {
  const bool quick = argc > 1 && std::string(argv[1]) == "quick";   // no random batches: for a slow C compiler
  auto timed = [](const char* what, void (*f)()) {
    auto t0 = std::chrono::steady_clock::now();
    f();
    if (std::getenv("NFCUOP_TIMING"))
      std::printf("  %-22s %.1f s\n", what, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
  };
  timed("structure", structure);
  if (!quick) {
    timed("random scalars", random_scalars);
    timed("random int tensors", random_int_tensors);
    timed("random float tensors", random_float_tensors);
  }
  timed("dtypes", dtypes);
  timed("numpy api", numpy_api);
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
