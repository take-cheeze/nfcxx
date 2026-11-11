// One imported ONNX model on nfcxx's C backend: hir::Graph::from_onnx, the Lowerer, then the median of RUNS Session::eval calls
// with Backend::C after WARM warm-up runs (the first call compiles the module). The input is raw float32 (--input) of the shape
// given by --shape; the output is written as raw float32 (--out) and a JSON line is printed for models.py.
//
//   bench_models --onnx=FILE --input=FILE.bin --shape=1,784 --out=FILE.bin [--runs=10] [--warm=3]
//
// NFCUOP_TRACE=FILE also writes the timed runs as Chrome trace-event JSON: one "run" span per run and one "kernel" span per
// kernel of it (named by the kernel's op, dtype and shape), each with its run index. Open the file in https://ui.perfetto.dev.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>

#include "nfcuop.hpp"
#include "nfcuop_hir.hpp"
#include "nfcuop_ut.hpp"

using namespace nfcuop;

static std::string read_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}

static double median(std::vector<double> v) {
  std::sort(v.begin(), v.end());
  size_t n = v.size();
  return n % 2 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

int main(int argc, char** argv) {
  std::string onnx, input, out, shape_s;
  int runs = 10, warm = 3;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto after = [&](const char* k) { return a.substr(std::strlen(k)); };
    if (a.rfind("--onnx=", 0) == 0) onnx = after("--onnx=");
    else if (a.rfind("--input=", 0) == 0) input = after("--input=");
    else if (a.rfind("--out=", 0) == 0) out = after("--out=");
    else if (a.rfind("--shape=", 0) == 0) shape_s = after("--shape=");
    else if (a.rfind("--runs=", 0) == 0) runs = std::stoi(after("--runs="));
    else if (a.rfind("--warm=", 0) == 0) warm = std::stoi(after("--warm="));
    else { std::fprintf(stderr, "unknown argument %s\n", a.c_str()); return 2; }
  }
  if (onnx.empty() || input.empty() || out.empty() || shape_s.empty()) {
    std::fprintf(stderr, "usage: bench_models --onnx=FILE --input=FILE.bin --shape=D0,D1,... --out=FILE.bin\n");
    return 2;
  }

  Shape shape;
  {
    std::stringstream ss(shape_s);
    std::string tok;
    while (std::getline(ss, tok, ',')) shape.push_back(std::stoll(tok));
  }
  size_t numel = 1;
  for (int64_t d : shape) numel *= static_cast<size_t>(d);

  std::string raw = read_file(input);
  if (raw.size() != numel * sizeof(float)) {
    std::fprintf(stderr, "input has %zu bytes, shape wants %zu\n", raw.size(), numel * sizeof(float));
    return 1;
  }
  std::vector<double> xs(numel);
  for (size_t i = 0; i < numel; i++) {
    float f;
    std::memcpy(&f, raw.data() + i * sizeof(float), sizeof(float));
    xs[i] = f;
  }
  // The model's one input is named x (models.py exports it so); the weights are the graph's own initializers.
  std::map<std::string, Array> feeds{{"x", Array::from_doubles(DType::Float32, shape, xs)}};

  std::string bytes = read_file(onnx);
  std::vector<int> ids;
  hir::Graph g = hir::Graph::from_onnx(bytes, &ids);
  if (ids.size() != 1) {
    std::fprintf(stderr, "expected one output, got %zu\n", ids.size());
    return 1;
  }
  ut::Session us;
  hir::Lowerer low(g, us);
  // The C backend: the Session compiles the lowered graph once (cached) and feeds its buffers (the weights) itself; the
  // timed call is Session::eval, so it includes that per-call feed handling.
  ut::Tensor y = low.get(ids[0]);
  us.backend = ut::Session::Backend::C;
  Array res = us.eval(y, feeds);   // the first call compiles and loads the module; not timed
  for (int i = 1; i < warm; i++) res = us.eval(y, feeds);
  us.clear_kernel_timings();   // the trace covers the timed runs only
  std::vector<double> ts;
  for (int i = 0; i < runs; i++) {
    auto t0 = std::chrono::steady_clock::now();
    res = us.eval(y, feeds);
    auto t1 = std::chrono::steady_clock::now();
    ts.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
  }

  if (const char* trace = std::getenv("NFCUOP_TRACE"); trace && *trace) {
    std::ofstream t(trace);
    t << "[\n";
    const std::vector<nfcuop::KernelTiming>& kt = us.kernel_timings();
    for (size_t i = 0; i < kt.size(); i++)
      t << (i ? ",\n" : "") << "{\"name\": \"" << kt[i].name << "\", \"cat\": \"" << (kt[i].name == "run" ? "run" : "kernel")
        << "\", \"ph\": \"X\", \"ts\": " << std::fixed << std::setprecision(3) << kt[i].ts_us << ", \"dur\": " << kt[i].dur_us
        << ", \"pid\": 1, \"tid\": 1, \"args\": {\"run\": " << kt[i].run << "}}";
    t << "\n]\n";
  }

  std::ofstream f(out, std::ios::binary);
  for (const Scalar& s : res.data) {
    float v = static_cast<float>(s.as_double());
    f.write(reinterpret_cast<const char*>(&v), sizeof(float));
  }
  f.close();

  std::printf("{\"backend\": \"nfcxx-c\", \"median_ms\": %.6f, \"min_ms\": %.6f, \"runs\": %d, \"shape\": [", median(ts),
              *std::min_element(ts.begin(), ts.end()), runs);
  for (size_t i = 0; i < res.shape.size(); i++) std::printf("%s%lld", i ? ", " : "", static_cast<long long>(res.shape[i]));
  std::printf("]}\n");
  return 0;
}
