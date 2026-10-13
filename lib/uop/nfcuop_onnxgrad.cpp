// nfcuop::hir::gradients_via_onnxsim: export the loss' sub-graph, let onnxsim differentiate it, merge the result back.
// See nfcuop_onnxgrad.hpp and docs/notes/uop-autodiff.md.
#include "nfcuop_onnxgrad.hpp"

#include <dlfcn.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

namespace nfcuop {
namespace hir {

namespace {

std::string env(const char* name) {
  const char* v = std::getenv(name);
  return v ? v : "";
}
bool file_exists(const std::string& p) {
  std::ifstream f(p.c_str(), std::ios::binary);
  return static_cast<bool>(f);
}
std::string dir_of_this_file() {
  std::string f = __FILE__;
  size_t s = f.rfind('/');
  return s == std::string::npos ? "." : f.substr(0, s);
}
std::string sh_quote(const std::string& s) {
  std::string out = "'";
  for (char c : s) out += c == '\'' ? std::string("'\\''") : std::string(1, c);
  return out + "'";
}
std::string read_file(const std::string& p) {
  std::ifstream f(p.c_str(), std::ios::binary);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}
void write_file(const std::string& p, const std::string& bytes) {
  std::ofstream f(p.c_str(), std::ios::binary);
  f.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  if (!f) throw Error("onnxsim: cannot write " + p);
}

// ---- way 1: the shared library ----

struct Library {
  void* handle = nullptr;
  int (*gradients)(const char*, size_t, const char*, const char* const*, size_t, const char*, char**, size_t*, char**) = nullptr;
  void (*release)(void*) = nullptr;
  std::string path, why;
};

Library& library() {
  static Library lib = [] {
    Library l;
    std::vector<std::string> paths;
    if (!env("NFCUOP_ONNXSIM").empty()) {   // an explicit path is the only one tried
      paths.push_back(env("NFCUOP_ONNXSIM"));
    } else {
      paths.push_back("build/onnxsim/libnfconnxsim.so");
      paths.push_back(dir_of_this_file() + "/../../build/onnxsim/libnfconnxsim.so");
    }
    std::string tried;
    for (const std::string& p : paths) {
      if (!file_exists(p)) { tried += (tried.empty() ? "" : ", ") + p; continue; }
      // The library throws and catches C++ exceptions inside (every operator without a rule is one). A program built by nfcxx
      // exports weak definitions of the C++ ABI's type_info vtables, without their virtual functions, and libstdc++ binds its
      // exception machinery to them: the first exception thrown in the library crashes in the unwinder. Such a program must be
      // linked with -Wl,--version-script=scripts/onnxsim/exe.map (nothing exported); otherwise the library is not used.
      if (void* vt = dlsym(RTLD_DEFAULT, "_ZTVN10__cxxabiv117__class_type_infoE")) {
        Dl_info di;
        if (dladdr(vt, &di) && di.dli_fname && std::string(di.dli_fname).find("libstdc++") == std::string::npos) {
          l.why = "this program defines the C++ ABI type_info itself (built by nfcxx?), which breaks exceptions inside " + p + "; link it with -Wl,--version-script=scripts/onnxsim/exe.map";
          return l;
        }
      }
      void* h = dlopen(p.c_str(), RTLD_NOW | RTLD_LOCAL);
      if (!h) {
        const char* e = dlerror();
        l.why = "cannot load " + p + ": " + (e ? e : "unknown error");
        return l;
      }
      l.handle = h;
      l.gradients = reinterpret_cast<decltype(l.gradients)>(dlsym(h, "nfc_onnxsim_gradients"));
      l.release = reinterpret_cast<decltype(l.release)>(dlsym(h, "nfc_onnxsim_free"));
      if (!l.gradients || !l.release) {
        l.handle = nullptr;
        l.why = p + " is not libnfconnxsim (no nfc_onnxsim_gradients)";
        return l;
      }
      l.path = p;
      return l;
    }
    l.why = "libnfconnxsim.so not found (looked for " + tried + "; build it with scripts/setup-onnxsim.sh or set NFCUOP_ONNXSIM)";
    return l;
  }();
  return lib;
}

// ---- way 2: scripts/onnx_grad.py in a subprocess ----

std::string python_command() {
  std::string p = env("NFCUOP_PYTHON");
  return p.empty() ? "python3" : p;
}
std::string script_path() {
  std::vector<std::string> paths;
  if (!env("NFCUOP_ONNX_GRAD").empty()) {   // an explicit path is the only one tried
    paths.push_back(env("NFCUOP_ONNX_GRAD"));
  } else {
    paths.push_back("scripts/onnx_grad.py");
    paths.push_back(dir_of_this_file() + "/../../scripts/onnx_grad.py");
  }
  for (const std::string& p : paths) if (file_exists(p)) return p;
  return "";
}

// A temporary directory that is removed with its (flat) content.
struct TempDir {
  std::string path;
  std::vector<std::string> files;
  TempDir() {
    std::string base = env("TMPDIR");
    if (base.empty()) base = "/tmp";
    std::string t = base + "/nfcuop-grad-XXXXXX";
    std::vector<char> buf(t.begin(), t.end());
    buf.push_back(0);
    if (!mkdtemp(buf.data())) throw Error("onnxsim: cannot create a temporary directory in " + base);
    path = buf.data();
  }
  std::string file(const std::string& n) { files.push_back(path + "/" + n); return files.back(); }
  ~TempDir() {
    for (const std::string& f : files) std::remove(f.c_str());
    rmdir(path.c_str());
  }
};

// Runs `cmd` through the shell with stdout and stderr in `log`; the exit status, or -1.
int run_shell(const std::string& cmd, const std::string& log) {
  int rc = std::system((cmd + " > " + sh_quote(log) + " 2>&1").c_str());
  if (rc == -1 || !WIFEXITED(rc)) return -1;
  return WEXITSTATUS(rc);
}

struct PythonState {
  bool ok = false;
  std::string info;
};
PythonState& python_state() {
  static PythonState st = [] {
    PythonState s;
    std::string script = script_path();
    if (script.empty()) { s.info = "scripts/onnx_grad.py not found (set NFCUOP_ONNX_GRAD)"; return s; }
    TempDir d;
    std::string log = d.file("check.log");
    int rc = run_shell(python_command() + " " + sh_quote(script) + " --check", log);
    std::string out = read_file(log);
    while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
    if (rc == 0) { s.ok = true; s.info = python_command() + " " + script + " (" + out + ")"; }
    else if (rc == 127) s.info = "python is not available (" + python_command() + " not found; set NFCUOP_PYTHON)";
    else s.info = "the python packages for " + script + " are missing: " + out;
    return s;
  }();
  return st;
}

enum class Way { Library, Python, None };
Way choose(std::string* info) {
  const std::string forced = env("NFCUOP_ONNXSIM_BACKEND");
  Library& lib = library();
  if (forced != "python" && lib.handle) { if (info) *info = "library " + lib.path; return Way::Library; }
  if (forced == "library") { if (info) *info = "onnxsim: " + lib.why; return Way::None; }
  PythonState& py = python_state();
  if (py.ok) { if (info) *info = "python " + py.info; return Way::Python; }
  if (info) *info = (forced == "python" ? "" : "C++ library: " + lib.why + "; ") + std::string("Python fallback: ") + py.info;
  return Way::None;
}

// the ModelProto with the gradients, from the forward model
std::string differentiate(Way way, const std::string& model, const std::string& loss, const std::vector<std::string>& wrt, const std::string& prefix) {
  if (way == Way::Library) {
    Library& lib = library();
    std::vector<const char*> names;
    for (const std::string& w : wrt) names.push_back(w.c_str());
    char *out = nullptr, *err = nullptr;
    size_t n = 0;
    int rc = lib.gradients(model.data(), model.size(), loss.c_str(), names.data(), names.size(), prefix.c_str(), &out, &n, &err);
    std::string msg = err ? err : "";
    std::string res = out ? std::string(out, n) : "";
    if (out) lib.release(out);
    if (err) lib.release(err);
    if (rc == 1) throw Error("onnxsim has no gradient rule for this graph: " + msg);
    if (rc != 0) throw Error("onnxsim failed: " + msg);
    return res;
  }
  TempDir d;
  std::string in = d.file("forward.onnx"), out = d.file("grad.onnx"), log = d.file("run.log");
  write_file(in, model);
  std::string cmd = python_command() + " " + sh_quote(script_path()) + " --model " + sh_quote(in) + " --out " + sh_quote(out) + " --loss " + sh_quote(loss) + " --prefix " + sh_quote(prefix);
  for (const std::string& w : wrt) cmd += " --wrt " + sh_quote(w);
  int rc = run_shell(cmd, log);
  std::string text = read_file(log);
  while (!text.empty() && (text.back() == '\n' || text.back() == ' ')) text.pop_back();
  if (rc == 3) throw Error("onnxsim has no gradient rule for this graph: " + text);
  if (rc != 0) throw Error("onnxsim (python) failed with status " + std::to_string(rc) + ": " + text);
  return read_file(out);
}

}  // namespace

bool onnxsim_available(std::string* info) {
  std::string s;
  Way w = choose(&s);
  if (info) *info = s;
  return w != Way::None;
}

std::vector<int> gradients_via_onnxsim(Graph& g, int loss, const std::vector<int>& wrt) {
  const Value& lv = g.value(loss);
  if (!is_float(lv.dtype) || !lv.shape.empty())
    throw Error("gradients: the loss " + lv.name + " must be a float value with an empty shape, it is " + name(lv.dtype) + to_string(lv.shape) + " (reduce it with sum() or mean())");
  for (int w : wrt) {
    const Value& v = g.value(w);
    if (!is_float(v.dtype)) throw Error("gradients: cannot differentiate with respect to " + v.name + " of type " + name(v.dtype));
  }
  if (wrt.empty()) return {};
  // the values the loss is computed from (an explicit stack: graphs can be deep)
  std::vector<bool> in_loss(g.num_values(), false);
  std::vector<int> stack = {loss};
  in_loss[static_cast<size_t>(loss)] = true;
  while (!stack.empty()) {
    int v = stack.back();
    stack.pop_back();
    int p = g.producer(v);
    if (p < 0) continue;
    for (int in : g.nodes()[static_cast<size_t>(p)].inputs)
      if (in >= 0 && !in_loss[static_cast<size_t>(in)]) { in_loss[static_cast<size_t>(in)] = true; stack.push_back(in); }
  }

  std::vector<int> result(wrt.size(), -1);
  std::vector<std::string> names;
  std::vector<size_t> where;  // index in `wrt` of each name sent to onnxsim
  for (size_t k = 0; k < wrt.size(); k++) {
    if (in_loss[static_cast<size_t>(wrt[k])]) { names.push_back(g.value(wrt[k]).name); where.push_back(k); continue; }
    // not in the loss' sub-graph: zero (Expand of a scalar 0 to the shape)
    const Value v = g.value(wrt[k]);
    int zero = g.add_initializer("", Array::full(v.dtype, {}, Scalar::from_double(v.dtype, 0)));
    if (v.shape.empty()) { result[k] = g.add_node("Identity", {zero}); continue; }
    Array sh(DType::Int64, {static_cast<int64_t>(v.shape.size())}, {});
    for (int64_t d : v.shape) sh.data.push_back(Scalar::from_int(DType::Int64, d));
    result[k] = g.add_node("Expand", {zero, g.add_initializer("", sh)});
  }
  if (names.empty()) return result;
  std::string info;
  Way way = choose(&info);
  if (way == Way::None) throw Error("gradients: onnxsim is not available (" + info + "); see docs/notes/uop-autodiff.md");

  int out = loss;
  if (g.producer(loss) < 0) out = g.add_node("Identity", {loss});  // to_onnx wants a node output
  std::string model = g.to_onnx({out});
  const std::string loss_name = g.value(out).name;
  const std::string prefix = "nfcg" + std::to_string(g.num_values()) + "_";
  std::string grad_model = differentiate(way, model, loss_name, names, prefix);
  std::vector<int> outs = g.merge_onnx(grad_model);
  if (outs.size() != names.size()) throw Error("onnxsim returned " + std::to_string(outs.size()) + " gradients for " + std::to_string(names.size()) + " values");
  for (size_t j = 0; j < where.size(); j++) {
    const Value& want = g.value(wrt[where[j]]);
    const Value& got = g.value(outs[j]);
    if (got.dtype != want.dtype || got.shape != want.shape)
      throw Error("onnxsim returned a gradient of " + std::string(name(got.dtype)) + to_string(got.shape) + " for " + want.name + " of " + name(want.dtype) + to_string(want.shape));
    result[where[j]] = outs[j];
  }
  return result;
}

}  // namespace hir
}  // namespace nfcuop
