// Benchmark through nfcxx's numpy-like API (nfcuop::np): the same float32 expressions (add, mul, sqrt, sum over the vector;
// square matmul) run on each back end the Session has (the interpreter, the C backend, ONNX Runtime and tinygrad), timed as
// the median of RUNS runs after WARM warm-up runs, and checked against the interpreter. The WebGPU run of the elementwise and
// sum cases is written as WebGPU cases for tests/uop/perf/run_webgpu.sh (matmul is refused by render_wgsl).
//
// Usage: bench_np [--max-n=N] [--only=OP] [--case-dir=DIR]  -> one JSON line per (case, back end) on stdout.
// NFCUOP_TRACE=FILE writes the spans (one per run, and the build of each back end) as Chrome trace-event JSON.
//
// What is timed: the call that runs the back end on the feeds (Session::eval_all for the interpreter, ORT and tinygrad;
// CModule::run for the C backend, compiled once before the clock). The feeds and the results are Array values, so the
// conversion between Arrays and back-end buffers is inside the timed call; the notes in docs/notes/uop-perf-bench.md say so.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_cgen.hpp"
#include "nfcuop_np.hpp"
#include "nfcuop_wgsl.hpp"

using namespace nfcuop;
using namespace nfcuop::np;

static const int WARM = 2, RUNS = 10;

// ---- trace (Chrome trace-event JSON: an array of ph "X" events, timestamps in microseconds) ----
struct TraceEvent { std::string name, backend, op; int64_t n; std::string phase; double ts, dur; };
static std::vector<TraceEvent> trace_events;
static const char* trace_path = nullptr;
static std::chrono::steady_clock::time_point trace_t0 = std::chrono::steady_clock::now();

static double us_now() {
  return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - trace_t0).count();
}

static void add_span(const std::string& name, const std::string& backend, const std::string& op, int64_t n,
                     const std::string& phase, double t0, double t1) {
  if (trace_path) trace_events.push_back({name, backend, op, n, phase, t0, t1 - t0});
}

static void write_trace() {
  if (!trace_path) return;
  std::ofstream f(trace_path);
  f << "[\n";
  for (size_t i = 0; i < trace_events.size(); i++) {
    const TraceEvent& e = trace_events[i];
    f << (i ? ",\n" : "") << "{\"name\": \"" << e.name << "\", \"cat\": \"" << e.backend << "\", \"ph\": \"X\", \"ts\": "
      << static_cast<int64_t>(e.ts) << ", \"dur\": " << static_cast<int64_t>(e.dur) << ", \"pid\": 1, \"tid\": 1, \"args\": {\"backend\": \""
      << e.backend << "\", \"op\": \"" << e.op << "\", \"n\": " << e.n << ", \"phase\": \"" << e.phase << "\"}}";
  }
  f << "\n]\n";
}

// ---- a case: one numpy-style expression over placeholders, with its feeds ----
struct Case {
  std::string op;                       // add, mul, sqrt, sum, matmul
  int64_t n;                            // the vector length, or the matrix side for matmul
  Tensor out;
  std::map<std::string, Array> feeds;
  std::string label() const { return op + " n=" + std::to_string(n); }
};

static Case make_case(Session& np, const std::string& op, int64_t n) {
  Case c{op, n, {}, {}};
  if (op == "matmul") {
    Tensor a = np.placeholder("a", {n, n}, DType::Float32), b = np.placeholder("b", {n, n}, DType::Float32);
    c.out = matmul(a, b);
    std::vector<double> va(n * n), vb(n * n);
    for (int64_t i = 0; i < n * n; i++) { va[i] = std::sin(0.001 * i); vb[i] = std::cos(0.002 * i); }
    c.feeds = {{"a", Array::from_doubles(DType::Float32, {n, n}, va)}, {"b", Array::from_doubles(DType::Float32, {n, n}, vb)}};
    return c;
  }
  Tensor x = np.placeholder("x", {n}, DType::Float32), y = np.placeholder("y", {n}, DType::Float32);
  std::vector<double> vx(n), vy(n);
  for (int64_t i = 0; i < n; i++) { vx[i] = 0.5 + 0.001 * static_cast<double>(i % 1000); vy[i] = 1.5 - 0.0007 * static_cast<double>(i % 997); }
  c.feeds = {{"x", Array::from_doubles(DType::Float32, {n}, vx)}, {"y", Array::from_doubles(DType::Float32, {n}, vy)}};
  if (op == "add") c.out = x + y;
  else if (op == "mul") c.out = x * y;
  else if (op == "sqrt") c.out = x.sqrt();
  else if (op == "sum") c.out = x.sum();
  else throw Error("bench_np: unknown op " + op);
  return c;
}

// The median and the minimum of the timed runs, in milliseconds.
static void summarise(std::vector<double> ms, double& median, double& minimum) {
  std::sort(ms.begin(), ms.end());
  median = ms[ms.size() / 2];
  minimum = ms.front();
}

// Compares a back end's outputs with a reference: bit-exact, the largest per-element relative error, and the largest
// absolute error scaled by the largest magnitude of the reference (a per-element relative error is large where the reference
// is near zero, as the matmul's sums are).
static void compare(const std::vector<Array>& ref, const std::vector<Array>& got, bool& bit_exact, double& max_rel,
                    double& max_scaled) {
  bit_exact = true;
  max_rel = 0;
  max_scaled = 0;
  double ref_max = 0, abs_max = 0;
  for (size_t k = 0; k < ref.size(); k++) {
    if (ref[k].shape != got[k].shape || ref[k].data.size() != got[k].data.size()) {
      bit_exact = false; max_rel = max_scaled = 1e300; return;
    }
    for (size_t j = 0; j < ref[k].data.size(); j++) {
      double x = ref[k].data[j].f, y = got[k].data[j].f;
      if (!(ref[k].data[j] == got[k].data[j])) bit_exact = false;
      ref_max = std::max(ref_max, std::fabs(x));
      if (std::isnan(x) && std::isnan(y)) continue;
      double d = std::fabs(x - y);
      abs_max = std::max(abs_max, d);
      max_rel = std::max(max_rel, d / std::max(1e-30, std::fabs(x)));
    }
  }
  max_scaled = abs_max / std::max(1e-30, ref_max);
}

struct Result { std::string backend; int runs = RUNS; double median = 0, minimum = 0; bool bit_exact = false; double max_rel = 0;
                double max_scaled = 0; double truth_scaled = -1; std::string note; };

// Times one back end on a case. `run` is the timed call; `first` is the untimed result the check uses.
static Result time_backend(const std::string& backend, const Case& c, const std::function<std::vector<Array>()>& run,
                           const std::vector<Array>& ref, int runs = RUNS, const std::vector<Array>* truth = nullptr) {
  Result r;
  r.backend = backend;
  r.runs = runs;
  double t0 = us_now();
  std::vector<Array> got = run();   // the first call is part of the build (lowering, compile, the library's model)
  add_span("build " + c.label(), backend, c.op, c.n, "build", t0, us_now());
  compare(ref, got, r.bit_exact, r.max_rel, r.max_scaled);
  if (truth) { bool be; double mr; compare(*truth, got, be, mr, r.truth_scaled); }
  for (int w = 0; w < WARM; w++) {
    double s = us_now();
    run();
    add_span("warmup " + c.label(), backend, c.op, c.n, "warmup", s, us_now());
  }
  std::vector<double> ms;
  for (int i = 0; i < runs; i++) {
    double s = us_now();
    run();
    double e = us_now();
    add_span("run " + c.label(), backend, c.op, c.n, "run", s, e);
    ms.push_back((e - s) / 1000.0);
  }
  summarise(ms, r.median, r.minimum);
  return r;
}

// The float64 reference of a matmul: the same product in float64 by the C backend (the interpreter's 1024 is out of memory).
static std::vector<Array> float64_truth(const Case& c) {
  Session t;
  int64_t n = c.n;
  Tensor a = t.placeholder("a", {n, n}, DType::Float64), b = t.placeholder("b", {n, n}, DType::Float64);
  Tensor out = matmul(a, b);
  std::map<std::string, Array> feeds;
  for (const auto& kv : c.feeds) {
    std::vector<double> v;
    for (const Scalar& s : kv.second.data) v.push_back(s.f);
    feeds[kv.first] = Array::from_doubles(DType::Float64, kv.second.shape, v);
  }
  ut::Tensor low = t.lower(out);
  std::shared_ptr<CModule> m = CModule::compile(render_c({low.uop()}));
  return m->run(feeds);
}

static void print_result(const Case& c, const Result& r) {
  std::string truth = r.truth_scaled < 0 ? "" : ", \"max_err_vs_float64_scaled\": " + std::to_string(r.truth_scaled);
  std::printf("{\"backend\": \"%s\", \"op\": \"%s\", \"n\": %lld, \"median_ms\": %.4f, \"min_ms\": %.4f, \"runs\": %d, "
              "\"bit_exact_vs_interpreter\": %s, \"max_rel_err_vs_interpreter\": %.3g, \"max_err_vs_interpreter_scaled\": %.3g%s%s}\n",
              r.backend.c_str(), c.op.c_str(), static_cast<long long>(c.n), r.median, r.minimum, r.runs,
              r.bit_exact ? "true" : "false", r.max_rel, r.max_scaled, truth.c_str(),
              r.note.empty() ? "" : (", \"note\": \"" + r.note + "\"").c_str());
  std::fflush(stdout);
}

// The WebGPU case file for tests/uop/perf/run_webgpu.html: the module, its buffers and kernels, the inputs, and the expected output.
static void write_webgpu_case(const std::string& path, const WgslProgram& p, const Case& c, const Array& expected) {
  std::ofstream f(path);
  f << "window.CASE = {\n  source: `" << p.source << "`,\n  buffers: [";
  for (size_t b = 0; b < p.buffers.size(); b++)
    f << (b ? ", " : "") << "{name: \"" << p.buffers[b].name << "\", count: " << p.buffers[b].count
      << ", input: " << (p.buffers[b].input ? "true" : "false") << "}";
  f << "],\n  kernels: [";
  for (size_t k = 0; k < p.kernels.size(); k++) {
    const WgslKernel& kr = p.kernels[k];
    f << (k ? ", " : "") << "{entry: \"" << kr.entry << "\", out: " << kr.out << ", count: " << kr.count << ", bindings: [";
    for (size_t j = 0; j < kr.bindings.size(); j++) f << (j ? ", " : "") << kr.bindings[j];
    f << "]}";
  }
  f << "],\n  output: " << p.output << ",\n  expected: [";
  for (size_t i = 0; i < expected.data.size(); i++) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.9g", expected.data[i].f);
    f << (i ? "," : "") << buf;
  }
  f << "],\n  inputs: {";
  bool first = true;
  for (const auto& kv : c.feeds) {
    f << (first ? "" : ", ") << kv.first << ": [";
    first = false;
    for (size_t i = 0; i < kv.second.data.size(); i++) {
      char buf[64];
      std::snprintf(buf, sizeof buf, "%.9g", kv.second.data[i].f);
      f << (i ? "," : "") << buf;
    }
    f << "]";
  }
  f << "}\n};\n";
}

// The same case as write_webgpu_case, for tests/uop/wgsl/dawn/run_dawn: the WGSL source, and the line spec that
// to_spec.js writes from the .js file (its own output, the buffers, the feeds, the kernels, the expected values).
// Written from C++ because a 2^24 case is larger than Node's maximum string length.
static void write_webgpu_spec(const std::string& prefix, const WgslProgram& p, const Case& c, const Array& expected) {
  std::ofstream w(prefix + ".wgsl", std::ios::binary);
  w << p.source;
  std::ofstream f(prefix + ".spec");
  f << "output " << p.output << "\n";
  for (size_t b = 0; b < p.buffers.size(); b++)
    f << "buf " << b << " " << p.buffers[b].count << " " << (p.buffers[b].input ? 1 : 0) << "\n";
  for (const auto& kv : c.feeds) {
    size_t idx = 0;
    while (idx < p.buffers.size() && p.buffers[idx].name != kv.first) idx++;
    if (idx == p.buffers.size()) continue;   // a placeholder the lowered graph does not read (no buffer)
    f << "input " << idx;
    for (const auto& v : kv.second.data) {
      char buf[64];
      std::snprintf(buf, sizeof buf, "%.9g", v.f);
      f << " " << buf;
    }
    f << "\n";
  }
  for (const WgslKernel& kr : p.kernels) {
    f << "kernel " << kr.entry << " " << kr.count;
    for (const auto& b : kr.bindings) f << " " << b;
    f << "\n";
  }
  f << "expect";
  for (const auto& v : expected.data) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.9g", v.f);
    f << " " << buf;
  }
  f << "\n";
}

int main(int argc, char** argv) {
  int64_t max_n = 1 << 24;
  std::string case_dir, only;
  for (int i = 1; i < argc; i++) {
    if (std::strncmp(argv[i], "--max-n=", 8) == 0) max_n = std::atoll(argv[i] + 8);
    else if (std::strncmp(argv[i], "--case-dir=", 11) == 0) case_dir = argv[i] + 11;
    else if (std::strncmp(argv[i], "--only=", 7) == 0) only = argv[i] + 7;
  }
  trace_path = std::getenv("NFCUOP_TRACE");
  if (trace_path && !*trace_path) trace_path = nullptr;

  std::vector<std::pair<std::string, int64_t>> plan;
  for (int64_t n : {int64_t(1) << 16, int64_t(1) << 20, int64_t(1) << 24})
    if (n <= max_n) for (const char* op : {"add", "mul", "sqrt", "sum"}) plan.push_back({op, n});
  for (int64_t n : {256, 512, 1024})
    if (n <= max_n) plan.push_back({"matmul", n});

  for (const auto& pl : plan) {
    if (!only.empty() && pl.first != only) continue;
    Session np;
    Case c = make_case(np, pl.first, pl.second);
    std::vector<Array> truth;
    if (c.op == "matmul") truth = float64_truth(c);
    const std::vector<Array>* tp = c.op == "matmul" ? &truth : nullptr;
    // The reference is the interpreter. For a 1024 matmul it is skipped: the lowering is about 1e9 scalar operations and
    // runs out of memory, so the C backend's result is the reference there (the 512 matmul checks the two against each other).
    bool interp_ok = !(c.op == "matmul" && c.n >= 1024);
    std::vector<Array> ref;
    if (interp_ok) {
      double t0 = us_now();
      np.backend = ut::Session::Backend::Interpreter;
      ref = np.eval_all({c.out}, c.feeds);
      add_span("build " + c.label(), "interpreter", c.op, c.n, "build", t0, us_now());
      int interp_runs = (c.op == "matmul" && c.n >= 512) ? 3 : RUNS;
      print_result(c, time_backend("interpreter", c, [&] { return np.eval_all({c.out}, c.feeds); }, ref, interp_runs, tp));
    }

    // The C backend: the program is compiled once, before the clock starts (its build is traced separately).
    std::shared_ptr<CModule> m;
    {
      double t0 = us_now();
      ut::Tensor lowered = np.lower(c.out);
      CProgram prog = render_c({lowered.uop()});
      m = CModule::compile(prog);
      add_span("compile " + c.label(), "c", c.op, c.n, "build", t0, us_now());
    }
    if (!interp_ok) {
      ref = m->run(c.feeds);
      Result skip;
      skip.backend = "interpreter";
      skip.runs = 0;
      skip.note = "skipped: the interpreter's lowering of a 1024 matmul is about 1e9 scalar operations (out of memory); the C backend is the reference";
      print_result(c, skip);
    }
    {
      Result rc = time_backend("c", c, [&] { return m->run(c.feeds); }, ref, RUNS, tp);
      if (!interp_ok) rc.note = "reference is the C backend (interpreter skipped)";
      print_result(c, rc);
    }

    np.backend = ut::Session::Backend::Ort;
    {
      Result ro;
      try {
        ro = time_backend("onnxruntime", c, [&] { return np.eval_all({c.out}, c.feeds); }, ref, RUNS, tp);
      } catch (const Error& e) {
        ro.backend = "onnxruntime";
        ro.note = std::string("unavailable: ") + e.what();
      }
      print_result(c, ro);
    }

    np.backend = ut::Session::Backend::Tinygrad;
    {
      Result rt;
      try {
        rt = time_backend("tinygrad", c, [&] { return np.eval_all({c.out}, c.feeds); }, ref, RUNS, tp);
      } catch (const Error& e) {
        rt.backend = "tinygrad";
        rt.note = std::string("unavailable: ") + e.what();
      }
      print_result(c, rt);
    }

    // The WebGPU run (tests/uop/perf/run_webgpu.sh): the WGSL module of the lowered graph, if render_wgsl takes it.
    {
      ut::Tensor lowered = np.lower(c.out);
      try {
        WgslProgram wp = render_wgsl(lowered.uop());
        if (!case_dir.empty()) {
          std::string prefix = case_dir + "/" + c.op + "_" + std::to_string(c.n);
          write_webgpu_case(prefix + ".js", wp, c, ref[0]);
          write_webgpu_spec(prefix, wp, c, ref[0]);
        }
        std::printf("{\"backend\": \"webgpu\", \"op\": \"%s\", \"n\": %lld, \"case\": \"written\"}\n", c.op.c_str(),
                    static_cast<long long>(c.n));
      } catch (const Error& e) {
        std::printf("{\"backend\": \"webgpu\", \"op\": \"%s\", \"n\": %lld, \"case\": \"refused\", \"note\": \"%s\"}\n",
                    c.op.c_str(), static_cast<long long>(c.n), e.what());
      }
      std::fflush(stdout);
    }
  }
  write_trace();
  return 0;
}
