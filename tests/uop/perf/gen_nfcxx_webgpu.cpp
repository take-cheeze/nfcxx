// The WebGPU benchmark's elementwise and reduction ops (add, mul, sqrt, sum), written with nfcuop::np, the numpy-like API. Each
// graph is lowered to UOps and rendered to WGSL (nfcuop_wgsl.hpp). Writes into the directory argv[1]:
//   bench_cases.js  window.BENCH_CASES, the cases webgpu_bench.html times (the format of gen_webgpu.py), at 2^16, 2^20, 2^24
//   check_<op>.js   window.CASE, one case per op at 2^10, for tests/uop/wgsl/run.html, which compares the GPU result with the
//                   numpy API's own values (Session::eval)
// Matmul is not here: the WGSL renderer refuses movement ops (docs/notes/uop-wgsl.md), so it stays with gen_webgpu.py.
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_np.hpp"
#include "nfcuop_wgsl.hpp"

using namespace nfcuop;

static const std::vector<int64_t> kVec = {int64_t{1} << 16, int64_t{1} << 20, int64_t{1} << 24};
static const std::vector<std::string> kOps = {"add", "mul", "sqrt", "sum"};
static const int64_t kCheckSize = int64_t{1} << 10;

// The inputs: the values the harness uses, in [0.5, 1.5), so sqrt is defined everywhere.
static Array input(const Shape& shape) {
  std::vector<double> v;
  for (int64_t i = 0; i < numel(shape); i++)
    v.push_back(0.5 + static_cast<double>((static_cast<uint64_t>(i) * 2654435761u) & 0xffffffffu) / 4294967296.0);
  return Array::from_doubles(DType::Float32, shape, v);
}

// The numpy-API graph of `op` on the placeholders x and y.
static np::Tensor build(const std::string& op, const np::Tensor& x, const np::Tensor& y) {
  if (op == "add") return np::add(x, y);
  if (op == "mul") return np::multiply(x, y);
  if (op == "sqrt") return x.sqrt();
  // keepdims: the full reduction without keepdims squeezes its result to a scalar, a Reshape the renderer refuses; the value is
  // the same, and the result has shape {1}
  if (op == "sum") return x.sum({0}, true);
  throw Error("gen_nfcxx_webgpu: unknown op " + op);
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

// A JSON string: the WGSL source has newlines and quotes.
static std::string js_string(const std::string& s) {
  std::string o = "\"";
  for (char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\t': o += "\\t"; break;
      case '\r': break;
      default: o += c;
    }
  }
  return o + "\"";
}

struct Rendered {
  WgslProgram prog;
  std::map<std::string, Array> feeds;  // the input values by placeholder name
  Array expected;                      // the numpy API's result
};

// Builds `op` at size n through the numpy API, lowers it and renders the WGSL module.
static Rendered render_op(const std::string& op, int64_t n) {
  np::Session s;
  np::Tensor x = s.placeholder("x", {n});
  np::Tensor y = s.placeholder("y", {n});
  np::Tensor r = build(op, x, y);
  Rendered out;
  out.prog = render_wgsl(s.lower(r).uop());
  for (const WgslBuffer& b : out.prog.buffers)
    if (b.input) out.feeds[b.name] = input({b.count});
  out.expected = s.eval(r, out.feeds);
  return out;
}

// The kernels in the harness's format: the module, the entry, the workgroups (one invocation per element, 64 per workgroup)
// and the bindings (the buffer index is the binding number in the module).
static std::string bench_case(const std::string& op, int64_t n, const Rendered& rd) {
  std::string j = "{\"op\":\"" + op + "\",\"size\":" + std::to_string(n) + ",\"backend\":\"nfcxx-numpy-webgpu\",\"kernels\":[";
  for (size_t k = 0; k < rd.prog.kernels.size(); k++) {
    const WgslKernel& kr = rd.prog.kernels[k];
    const int64_t groups = (kr.count + 63) / 64;
    j += (k ? "," : "") + std::string("{\"source\":") + js_string(rd.prog.source) + ",\"entry\":\"" + kr.entry +
         "\",\"dispatch\":[" + std::to_string(groups) + ",1,1],\"binds\":[";
    for (size_t b = 0; b < kr.bindings.size(); b++)
      j += (b ? "," : "") + std::string("{\"binding\":") + std::to_string(kr.bindings[b]) + ",\"buf\":\"" +
           rd.prog.buffers[kr.bindings[b]].name + "\"}";
    j += "]}";
  }
  j += "],\"buffers\":{";
  for (size_t b = 0; b < rd.prog.buffers.size(); b++)
    j += (b ? "," : "") + std::string("\"") + rd.prog.buffers[b].name + "\":" + std::to_string(rd.prog.buffers[b].count);
  j += "},\"output\":\"" + rd.prog.buffers[rd.prog.output].name + "\"}";
  return j;
}

// The WGSL runner's case (tests/uop/wgsl/run.html): the module, buffers, kernels, the inputs and the expected output.
static void write_check(const std::string& path, const Rendered& rd) {
  std::ofstream f(path);
  f << "window.CASE = {\n  source: `" << rd.prog.source << "`,\n  buffers: [";
  for (size_t b = 0; b < rd.prog.buffers.size(); b++)
    f << (b ? ", " : "") << "{name: \"" << rd.prog.buffers[b].name << "\", count: " << rd.prog.buffers[b].count
      << ", input: " << (rd.prog.buffers[b].input ? "true" : "false") << "}";
  f << "],\n  kernels: [";
  for (size_t k = 0; k < rd.prog.kernels.size(); k++) {
    const WgslKernel& kr = rd.prog.kernels[k];
    f << (k ? ", " : "") << "{entry: \"" << kr.entry << "\", out: " << kr.out << ", count: " << kr.count << ", bindings: [";
    for (size_t j = 0; j < kr.bindings.size(); j++) f << (j ? ", " : "") << kr.bindings[j];
    f << "]}";
  }
  f << "],\n  output: " << rd.prog.output << ",\n  inputs: {";
  bool first = true;
  for (const auto& [name, arr] : rd.feeds) {
    f << (first ? "" : ", ") << name << ": " << js_array(arr);
    first = false;
  }
  f << "},\n  expected: " << js_array(rd.expected) << "\n};\n";
}

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: gen_nfcxx_webgpu OUT_DIR\n");
    return 2;
  }
  const std::string dir = argv[1];
  std::ofstream bench(dir + "/bench_cases.js");
  bench << "window.BENCH_CASES = [";
  bool first = true;
  for (int64_t n : kVec) {
    for (const std::string& op : kOps) {
      Rendered rd = render_op(op, n);
      bench << (first ? "" : ",\n") << bench_case(op, n, rd);
      first = false;
      std::fprintf(stderr, "%s %lld kernels %zu\n", op.c_str(), static_cast<long long>(n), rd.prog.kernels.size());
    }
  }
  bench << "];\n";
  for (const std::string& op : kOps) write_check(dir + "/check_" + op + ".js", render_op(op, kCheckSize));
  return 0;
}
