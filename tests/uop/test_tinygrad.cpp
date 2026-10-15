// The tinygrad back end (lib/uop/nfcuop_tinygrad.hpp): hir graphs exported with to_onnx and run by tinygrad, compared with the
// interpreter (hir::Evaluator). Float results must agree to a relative 1e-5 (an absolute 1e-6 near zero; NaN with NaN); integer and
// bool results exactly; shapes and dtypes exactly. Covered: a static graph with elementwise ops, reductions, Reshape/Transpose,
// Gemm/MatMul, integer Div/Mod, Greater/Where, a scalar output, an input as an output; float64, int32 and bool tensors; a symbolic
// batch run unbound and bound (Graph::bind) at two sizes; the numpy API with np.backend = Tinygrad; the errors (a missing feed, a
// wrong shape, a symbol with two sizes, a Python executable that does not start, a helper that does not exist, and a retry after
// such a failure).
// The embedded path (in-process CPython) is checked too: the path taken is the embedded one; a repeated call imports nothing and
// builds no runner (tinygrad::counts), and it is much faster than the subprocess path for the same graph; a call from another thread
// takes the subprocess path with the same values; an import that fails in a fresh process gives the Python traceback as the error.
// The Python executable is $NFCUOP_TINYGRAD_PYTHON (else python3). When tinygrad cannot be imported the test prints one line
// starting with SKIP and exits 0. The helper is found at $NFCUOP_TINYGRAD_SCRIPT, else scripts/tinygrad_run.py (run from the root).
// `test_tinygrad --import-probe` is the child process of the import check: it prints UNAVAILABLE and the reasons, or AVAILABLE.
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"
#include "nfcuop_np.hpp"
#include "nfcuop_tinygrad.hpp"

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
static const DType f32 = DType::Float32, f64 = DType::Float64, i64 = DType::Int64, i32 = DType::Int32, bl = DType::Bool;
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
  std::vector<Array> got = tinygrad::run(g, outs, feeds);
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

// The other dtypes: float64 arithmetic, an int32 Mul and ReduceSum, a bool Not and Or (each output is checked against the
// interpreter, and the dtypes are the graph's).
static void dtypes() {
  hir::Graph g;
  int d = g.add_input("d", f64, {4});
  int i = g.add_input("i", i32, {2, 2});
  int b = g.add_input("b", bl, {4});
  int half = g.add_initializer("half", arr(f64, {}, {0.5}));
  int dh = g.add_node("Mul", {d, half});
  int dd = g.add_node("Sqrt", {g.add_node("Abs", {dh})}, {}, "float64");
  int imul = g.add_node("Mul", {i, i}, {}, "int32");
  int ax = g.add_initializer("ax", arr(i64, {1}, {1}));
  int isum = g.add_node("ReduceSum", {imul, ax}, {hir::Attribute::Int("keepdims", 0)}, "int32_sum");
  int nb = g.add_node("Not", {b});
  int orb = g.add_node("Or", {nb, b}, {}, "bool");
  std::vector<int> outs = {dd, imul, isum, orb};
  std::map<std::string, Array> feeds = {
      {"d", arr(f64, {4}, {-3.25, 1.5, 0.0, 7.75})},
      {"i", arr(i32, {2, 2}, {2, -3, 4, 5})},
      {"b", arr(bl, {4}, {1, 0, 1, 0})},
  };
  std::vector<Array> want = interp(g, outs, feeds);
  std::vector<Array> got = tinygrad::run(g, outs, feeds);
  if (got.size() != outs.size()) { CHECK(false); return; }
  for (size_t k = 0; k < outs.size(); k++) expect_same("dtypes/" + g.value(outs[k]).name, got[k], want[k]);
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
    std::string tag = "batch N=" + std::to_string(n);
    // unbound: the graph has the symbol, tinygrad takes the size from the feed
    std::vector<Array> got = tinygrad::run(g, outs, feeds);
    if (got.size() != 2 || want.size() != 2) { CHECK(false); continue; }
    expect_same(tag + "/probs", got[0], want[0]);
    expect_same(tag + "/colsum", got[1], want[1]);
    CHECK(got[0].shape == (Shape{n, 2}) && got[1].shape == (Shape{3}));
    // bound (Graph::bind: every operator inferred again with the sizes) is a static model
    hir::Graph bound = g.bind({{"N", n}});
    std::vector<Array> got_b = tinygrad::run(bound, outs, feeds);
    if (got_b.size() == 2) {
      expect_same(tag + " bound/probs", got_b[0], want[0]);
      expect_same(tag + " bound/colsum", got_b[1], want[1]);
    } else {
      CHECK(false);
    }
  }
}

// The numpy API with np.backend = Tinygrad (eval and eval_all), against the same session on the interpreter.
static void numpy_selection() {
  nfcuop::np::Session np;
  auto x = np.placeholder("x", {2, 3});
  auto w = np.array({1, 0, 0, 1, 1, 1}, {3, 2});
  auto y = softmax(matmul(x, w) + np.array({0.5, -0.5}));
  auto z = matmul(x, w) * 2 - 1;
  std::map<std::string, Array> feeds = {{"x", arr(f32, {2, 3}, {0.25, -1, 2, 3, 0.5, -4})}};
  np.backend = ut::Session::Backend::Interpreter;
  Array want = np.eval(y, feeds);
  np.backend = ut::Session::Backend::Tinygrad;
  expect_same("np eval (tinygrad)", np.eval(y, feeds), want);
  std::vector<Array> both = np.eval_all({y, z}, feeds);
  np.backend = ut::Session::Backend::Interpreter;
  std::vector<Array> both_want = np.eval_all({y, z}, feeds);
  CHECK(both.size() == 2 && both_want.size() == 2);
  if (both.size() == 2 && both_want.size() == 2) {
    expect_same("np eval_all[0] (tinygrad)", both[0], both_want[0]);
    expect_same("np eval_all[1] (tinygrad)", both[1], both_want[1]);
  }
  // a placeholder is its own value: no model is run for it
  np.backend = ut::Session::Backend::Tinygrad;
  expect_same("np eval placeholder (tinygrad)", np.eval(x, feeds), feeds.at("x"));
  // the UOp-level session has no graph: it refuses the back end instead of rendering C for it
  ut::Session s;
  s.backend = ut::Session::Backend::Tinygrad;
  CHECK_ERR(s.eval(s.placeholder("p", {2}), {{"p", arr(f32, {2}, {1, 2})}}), "evaluate through np::Session");
}

// Errors: a feed that is missing, of the wrong shape, or a symbol with two sizes.
static void errors() {
  std::vector<int> outs;
  hir::Graph g = forward_graph(&outs);
  std::map<std::string, Array> feeds = forward_feeds();
  CHECK_ERR(tinygrad::run(g, {outs[4]}, {}), "no feed for input x");
  std::map<std::string, Array> wrong = feeds;
  wrong["x"] = arr(f32, {3, 2}, {1, 2, 3, 4, 5, 6});
  CHECK_ERR(tinygrad::run(g, {outs[0]}, wrong), "has shape");
  hir::Graph two;
  int a = two.add_symbolic_input("a", f32, hir::Dims{S("N"), 3});
  int b = two.add_symbolic_input("b", f32, hir::Dims{S("N"), 3});
  int s = two.add_node("Add", {a, b});
  CHECK_ERR(tinygrad::run(two, {s}, {{"a", arr(f32, {2, 3}, V(6, 1.0))}, {"b", arr(f32, {3, 3}, V(9, 1.0))}}), "symbol N");
}

// Failures of the helper: an executable that does not start, and a helper script that does not exist. The error carries the
// helper's text. Nothing is cached, so the call after the variables are restored runs the helper again.
static void failures(const hir::Graph& g, int out, const std::map<std::string, Array>& feeds) {
  const char* py = std::getenv("NFCUOP_TINYGRAD_PYTHON");
  const char* sc = std::getenv("NFCUOP_TINYGRAD_SCRIPT");
  std::string py0 = py ? py : "", sc0 = sc ? sc : "";
  setenv("NFCUOP_TINYGRAD_PYTHON", "/nonexistent/nfcuop-tinygrad/python", 1);
  CHECK_ERR(tinygrad::run(g, {out}, feeds), "cannot start");
  std::string why;
  CHECK(!tinygrad::available(&why));
  CHECK(why.find("cannot start") != std::string::npos);
  if (py0.empty()) unsetenv("NFCUOP_TINYGRAD_PYTHON");
  else setenv("NFCUOP_TINYGRAD_PYTHON", py0.c_str(), 1);
  // The helper is run only by the subprocess path, so its failure is tested with that path forced (NFCUOP_TINYGRAD_EMBED=0).
  const char* em = std::getenv("NFCUOP_TINYGRAD_EMBED");
  std::string em0 = em ? em : "";
  setenv("NFCUOP_TINYGRAD_EMBED", "0", 1);
  setenv("NFCUOP_TINYGRAD_SCRIPT", "/nonexistent/nfcuop-tinygrad/helper.py", 1);
  CHECK_ERR(tinygrad::run(g, {out}, feeds), "the helper failed");
  if (sc0.empty()) unsetenv("NFCUOP_TINYGRAD_SCRIPT");
  else setenv("NFCUOP_TINYGRAD_SCRIPT", sc0.c_str(), 1);
  if (em0.empty()) unsetenv("NFCUOP_TINYGRAD_EMBED");
  else setenv("NFCUOP_TINYGRAD_EMBED", em0.c_str(), 1);
  // restored: the same call runs (no failure was cached)
  std::vector<Array> again = tinygrad::run(g, {out}, feeds);
  CHECK(again.size() == 1);
}

// ---- the embedded path ----

static std::chrono::steady_clock::time_point now() { return std::chrono::steady_clock::now(); }
static double seconds_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double>(now() - t0).count();
}

// A repeated call takes the embedded path and reuses what the first one made: no tinygrad import and no OnnxRunner is built (the
// counts of this backend), and the values are the same. Its time is compared with the same call in a subprocess
// (NFCUOP_TINYGRAD_EMBED=0), which starts Python and imports tinygrad every time: the repeated embedded call must take less than a
// quarter of that. The counts are the backend's own bookkeeping; the time is the independent evidence that nothing is re-imported.
static void embedded_path(const hir::Graph& g, int out, const std::map<std::string, Array>& feeds) {
  std::vector<Array> first = tinygrad::run(g, {out}, feeds);
  if (tinygrad::last_path() != tinygrad::Path::Embedded) {
    std::printf("SKIP embedded path: %s\n", tinygrad::embedded_status().c_str());
    return;
  }
  CHECK(first.size() == 1);
  tinygrad::Counts before = tinygrad::counts();
  CHECK(before.imports == 1);
  auto t0 = now();
  std::vector<Array> again = tinygrad::run(g, {out}, feeds);
  double repeated = seconds_since(t0);
  tinygrad::Counts after = tinygrad::counts();
  CHECK(tinygrad::last_path() == tinygrad::Path::Embedded);
  CHECK(after.imports == before.imports);
  CHECK(after.runners == before.runners);
  CHECK(after.embedded_runs == before.embedded_runs + 1);
  if (first.size() == 1 && again.size() == 1) expect_same("embedded repeated call", again[0], first[0]);

  const char* em = std::getenv("NFCUOP_TINYGRAD_EMBED");
  std::string em0 = em ? em : "";
  setenv("NFCUOP_TINYGRAD_EMBED", "0", 1);
  t0 = now();
  std::vector<Array> sub = tinygrad::run(g, {out}, feeds);
  double subprocess = seconds_since(t0);
  if (em0.empty()) unsetenv("NFCUOP_TINYGRAD_EMBED");
  else setenv("NFCUOP_TINYGRAD_EMBED", em0.c_str(), 1);
  CHECK(tinygrad::last_path() == tinygrad::Path::Subprocess);
  CHECK(tinygrad::embedded_status().find("NFCUOP_TINYGRAD_EMBED=0") != std::string::npos);
  if (sub.size() == 1 && first.size() == 1) expect_same("subprocess call", sub[0], first[0]);
  CHECK(repeated * 4 < subprocess);
  std::printf("timing: repeated embedded call %.3f s; subprocess call of the same graph %.3f s\n", repeated, subprocess);
  // and the next call is embedded again
  tinygrad::run(g, {out}, feeds);
  CHECK(tinygrad::last_path() == tinygrad::Path::Embedded);
}

struct ThreadJob {
  const hir::Graph* g;
  int out;
  const std::map<std::string, Array>* feeds;
  std::vector<Array> got;
  std::string error;
};

static void* thread_call(void* p) {
  ThreadJob* j = static_cast<ThreadJob*>(p);
  try {
    j->got = tinygrad::run(*j->g, {j->out}, *j->feeds);
  } catch (const Error& e) {
    j->error = e.what();
  }
  return nullptr;
}

// The interpreter belongs to the thread that started it: a call from another thread takes the subprocess path, with the same values.
static void other_thread(const hir::Graph& g, int out, const std::map<std::string, Array>& feeds, const Array& want) {
  ThreadJob job{&g, out, &feeds, {}, ""};
  pthread_t th;
  if (pthread_create(&th, nullptr, thread_call, &job) != 0) {
    CHECK(false);
    return;
  }
  pthread_join(th, nullptr);
  CHECK(job.error.empty());
  CHECK(tinygrad::last_path() == tinygrad::Path::Subprocess);
  if (job.got.size() == 1) expect_same("other thread", job.got[0], want);
  else CHECK(false);
}

// argv[0] of this program, for the child process of import_failure
static std::string g_argv0;

// The import of tinygrad fails in a fresh process whose PYTHONPATH holds a tinygrad.py that raises ImportError. The embedded path's
// error is the traceback (an Error, not an abort), and the subprocess path follows it in the text. The child is this program with
// --import-probe, run from the same directory, in a shell (the test program only; the library starts no shell).
static void import_failure() {
  const char* em = std::getenv("NFCUOP_TINYGRAD_EMBED");
  if (em && std::strcmp(em, "0") == 0) {
    std::printf("SKIP import_failure: the embedded path is disabled (NFCUOP_TINYGRAD_EMBED=0)\n");
    return;
  }
  const char* t = std::getenv("TMPDIR");
  std::string base = std::string(t && *t ? t : "/tmp") + "/nfcuop-tinygrad-probe-XXXXXX";
  std::vector<char> buf(base.begin(), base.end());
  buf.push_back('\0');
  if (!mkdtemp(buf.data())) {
    CHECK(false);
    return;
  }
  std::string dir = buf.data();
  {
    std::ofstream mod(dir + "/tinygrad.py");
    mod << "raise ImportError('probe: no tinygrad here')\n";
  }
  const char* py = std::getenv("NFCUOP_TINYGRAD_PYTHON");
  std::string cmd = "PYTHONDONTWRITEBYTECODE=1 PYTHONPATH='" + dir + "' NFCUOP_TINYGRAD_PYTHON='" + std::string(py ? py : "python3") + "' '" + g_argv0 +
                    "' --import-probe > '" + dir + "/probe.txt' 2>&1";
  int rc = std::system(cmd.c_str());
  std::string text;
  {
    std::ifstream in(dir + "/probe.txt");
    std::string line;
    while (std::getline(in, line)) text += line + "\n";
  }
  CHECK(rc == 0);
  CHECK(text.find("UNAVAILABLE") != std::string::npos);
  CHECK(text.find("Traceback (most recent call last)") != std::string::npos);
  CHECK(text.find("ImportError: probe: no tinygrad here") != std::string::npos);
  CHECK(text.find("the embedded interpreter was not used") != std::string::npos);
  unlink((dir + "/tinygrad.py").c_str());
  unlink((dir + "/probe.txt").c_str());
  rmdir(dir.c_str());
}

int main(int argc, char** argv) {
  g_argv0 = argv[0];
  if (argc > 1 && std::strcmp(argv[1], "--import-probe") == 0) {
    std::string why;
    bool ok = tinygrad::available(&why);
    std::printf("%s\n%s\n", ok ? "AVAILABLE" : "UNAVAILABLE", why.c_str());
    return 0;
  }
  std::string why;
  if (!tinygrad::available(&why)) {
    std::printf("SKIP test_tinygrad: %s\n", why.c_str());
    return 0;
  }
  // an Error that escapes a section is a failed check with its message, not an abort
  auto section = [](const char* name, void (*fn)()) {
    try { fn(); } catch (const Error& e) { checks++; failed++; std::printf("FAIL %s: %s\n", name, e.what()); }
  };
  section("forward", forward);
  section("dtypes", dtypes);
  section("symbolic_batch", symbolic_batch);
  section("numpy_selection", numpy_selection);
  section("errors", errors);
  section("failures", [] {
    std::vector<int> outs;
    hir::Graph g = forward_graph(&outs);
    failures(g, outs[0], forward_feeds());
  });
  section("embedded_path", [] {
    std::vector<int> outs;
    hir::Graph g = forward_graph(&outs);
    embedded_path(g, outs[4], forward_feeds());
  });
  section("other_thread", [] {
    std::vector<int> outs;
    hir::Graph g = forward_graph(&outs);
    std::map<std::string, Array> feeds = forward_feeds();
    other_thread(g, outs[4], feeds, interp(g, {outs[4]}, feeds)[0]);
  });
  section("import_failure", import_failure);
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
