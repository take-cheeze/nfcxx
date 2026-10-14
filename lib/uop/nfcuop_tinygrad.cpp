// nfcuop tinygrad back end (nfcuop_tinygrad.hpp). The graph and the feeds go to a scratch directory; scripts/tinygrad_run.py runs
// the model with tinygrad and writes the outputs there; they are read back here. The file layout is documented in that script.
//
// The helper is started with fork and execvp, not through a shell: the arguments are passed as they are, so no name or path is
// quoted or interpolated. Its stderr goes to a file in the scratch directory, which becomes the text of the Error on failure.
// The scratch directory is removed when the call ends, on every path.
#include "nfcuop_tinygrad.hpp"

#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace nfcuop {
namespace tinygrad {
namespace {

std::string python_exe() {
  const char* p = std::getenv("NFCUOP_TINYGRAD_PYTHON");
  return p && *p ? p : "python3";
}

std::string helper_script() {
  const char* p = std::getenv("NFCUOP_TINYGRAD_SCRIPT");
  return p && *p ? p : "scripts/tinygrad_run.py";
}

// The scratch directory of one call: its files are named relative to it, and all of them are removed when it goes out of scope.
struct Scratch {
  std::string dir;
  std::vector<std::string> files;
  Scratch() {
    const char* t = std::getenv("TMPDIR");
    std::string tmpl = std::string(t && *t ? t : "/tmp") + "/nfcuop-tinygrad-XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    if (!mkdtemp(buf.data())) throw Error("nfcuop tinygrad: cannot create a scratch directory from " + tmpl + ": " + std::strerror(errno));
    dir = buf.data();
  }
  ~Scratch() {
    for (const std::string& f : files) unlink((dir + "/" + f).c_str());
    rmdir(dir.c_str());
  }
  Scratch(const Scratch&) = delete;
  Scratch& operator=(const Scratch&) = delete;
  // The path of file `f` of the directory; registered for removal.
  std::string path(const std::string& f) {
    files.push_back(f);
    return dir + "/" + f;
  }
};

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw Error("nfcuop tinygrad: cannot read " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

void write_file(const std::string& path, const std::string& bytes) {
  std::ofstream out(path, std::ios::binary);
  out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  if (!out) throw Error("nfcuop tinygrad: cannot write " + path);
}

std::string hex(const std::string& s) {
  static const char digits[] = "0123456789abcdef";
  std::string out;
  for (unsigned char c : s) {
    out += digits[c >> 4];
    out += digits[c & 15];
  }
  return out;
}

// Runs argv (argv[0] is looked up on PATH) with stdout to /dev/null and stderr to `err_file`. Returns the exit status; a process
// that cannot be started exits with 127 and says so on stderr.
int run_helper(const std::vector<std::string>& argv, const std::string& err_file) {
  std::vector<char*> args;
  for (const std::string& a : argv) args.push_back(const_cast<char*>(a.c_str()));
  args.push_back(nullptr);
  pid_t pid = fork();
  if (pid < 0) throw Error("nfcuop tinygrad: fork failed: " + std::string(std::strerror(errno)));
  if (pid == 0) {
    int efd = open(err_file.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (efd >= 0) {
      dup2(efd, 2);
      close(efd);
    }
    int nfd = open("/dev/null", O_WRONLY);
    if (nfd >= 0) {
      dup2(nfd, 1);
      close(nfd);
    }
    execvp(args[0], args.data());
    std::string msg = "nfcuop tinygrad: cannot start " + argv[0] + ": " + std::strerror(errno) + "\n";
    ssize_t ignored = write(2, msg.data(), msg.size());
    (void)ignored;
    _exit(127);
  }
  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) throw Error("nfcuop tinygrad: waitpid failed: " + std::string(std::strerror(errno)));
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return 128;  // killed by a signal
}

// The helper's stderr, or a note when it wrote none.
std::string stderr_text(const std::string& err_file) {
  std::string s = read_file(err_file);
  while (!s.empty() && (s.back() == '\n' || s.back() == ' ')) s.pop_back();
  return s.empty() ? "(no output on stderr)" : s;
}

size_t elem_size(DType d) {
  switch (d) {
    case DType::Bool: return 1;
    case DType::Int32: case DType::Float32: return 4;
    case DType::Int64: case DType::Float64: return 8;
  }
  return 0;
}

// The elements of an array in the raw layout of the helper (little endian, Bool one byte).
std::string to_bytes(const Array& a) {
  std::string out(a.data.size() * elem_size(a.dtype), '\0');
  char* p = &out[0];
  for (const Scalar& s : a.data) {
    switch (a.dtype) {
      case DType::Bool: { *p = s.i ? 1 : 0; break; }
      case DType::Int32: { int32_t v = static_cast<int32_t>(s.i); std::memcpy(p, &v, 4); break; }
      case DType::Int64: { int64_t v = s.i; std::memcpy(p, &v, 8); break; }
      case DType::Float32: { float v = static_cast<float>(s.f); std::memcpy(p, &v, 4); break; }
      case DType::Float64: { double v = s.f; std::memcpy(p, &v, 8); break; }
    }
    p += elem_size(a.dtype);
  }
  return out;
}

Array from_bytes(DType d, const Shape& shape, const std::string& bytes) {
  std::vector<Scalar> v;
  v.reserve(static_cast<size_t>(numel(shape)));
  const unsigned char* p = reinterpret_cast<const unsigned char*>(bytes.data());
  for (int64_t k = 0; k < numel(shape); k++, p += elem_size(d)) {
    switch (d) {
      case DType::Bool: v.push_back(Scalar::from_int(d, *p)); break;
      case DType::Int32: { int32_t x; std::memcpy(&x, p, 4); v.push_back(Scalar::from_int(d, x)); break; }
      case DType::Int64: { int64_t x; std::memcpy(&x, p, 8); v.push_back(Scalar::from_int(d, x)); break; }
      case DType::Float32: { float x; std::memcpy(&x, p, 4); v.push_back(Scalar::from_double(d, x)); break; }
      case DType::Float64: { double x; std::memcpy(&x, p, 8); v.push_back(Scalar::from_double(d, x)); break; }
    }
  }
  return Array(d, shape, std::move(v));
}

DType dtype_named(const std::string& s) {
  for (DType d : {DType::Bool, DType::Int32, DType::Int64, DType::Float32, DType::Float64})
    if (s == name(d)) return d;
  throw Error("nfcuop tinygrad: the helper wrote dtype " + s + ", which the backend does not read");
}

// The feed of graph input `id`: its dtype and rank must be the graph's, its static dimensions equal, and each symbol bound to
// one size (the first feed that has it fixes it).
void check_feed(const hir::Graph& g, int id, const Array& a, std::map<std::string, int64_t>& syms) {
  const hir::Value& v = g.value(id);
  if (a.dtype != v.dtype) throw Error("nfcuop tinygrad: feed " + v.name + " is " + name(a.dtype) + ", the graph has " + name(v.dtype));
  if (a.shape.size() != v.shape.size()) throw Error("nfcuop tinygrad: feed " + v.name + " has rank " + std::to_string(a.shape.size()) + ", the graph " + std::to_string(v.shape.size()));
  for (size_t k = 0; k < v.shape.size(); k++) {
    const std::string sym = v.syms.empty() ? "" : v.syms[k];
    if (sym.empty()) {
      if (a.shape[k] != v.shape[k]) throw Error("nfcuop tinygrad: feed " + v.name + " has shape " + to_string(a.shape) + ", the graph " + to_string(v.shape));
      continue;
    }
    auto it = syms.find(sym);
    if (it == syms.end()) syms[sym] = a.shape[k];
    else if (it->second != a.shape[k]) throw Error("nfcuop tinygrad: symbol " + sym + " is " + std::to_string(it->second) + " in one feed and " + std::to_string(a.shape[k]) + " in another");
  }
}

}  // namespace

bool available(std::string* why) {
  Scratch s;
  std::string err = s.path("stderr.txt");
  int status = run_helper({python_exe(), helper_script(), "--check"}, err);
  if (status == 0) return true;
  if (why) *why = "tinygrad is not available (" + python_exe() + " exited " + std::to_string(status) + "): " + stderr_text(err);
  return false;
}

std::vector<Array> run(const hir::Graph& g, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds) {
  std::vector<Array> result(outputs.size());
  // Outputs that are inputs or initializers are returned directly; the others are computed by the exported model.
  std::vector<int> computed;
  std::vector<size_t> slot;
  for (size_t k = 0; k < outputs.size(); k++) {
    int o = outputs[k];
    if (g.producer(o) >= 0) {
      computed.push_back(o);
      slot.push_back(k);
    } else if (const Array* a = g.initializer(o)) {
      result[k] = *a;
    } else {
      auto f = feeds.find(g.value(o).name);
      if (f == feeds.end()) throw Error("nfcuop tinygrad: no feed for input " + g.value(o).name);
      std::map<std::string, int64_t> syms;
      check_feed(g, o, f->second, syms);
      result[k] = f->second;
    }
  }
  if (computed.empty()) return result;

  // The inputs the computed outputs depend on (Graph::to_onnx writes exactly these).
  std::set<int> seen, inputs;
  std::vector<int> stack = computed;
  while (!stack.empty()) {
    int v = stack.back();
    stack.pop_back();
    if (!seen.insert(v).second) continue;
    int p = g.producer(v);
    if (p < 0) {
      if (!g.initializer(v)) inputs.insert(v);
      continue;
    }
    for (int in : g.nodes()[static_cast<size_t>(p)].inputs)
      if (in >= 0) stack.push_back(in);
  }
  std::map<std::string, int64_t> syms;
  for (int id : inputs) {
    const std::string& nm = g.value(id).name;
    auto f = feeds.find(nm);
    if (f == feeds.end()) throw Error("nfcuop tinygrad: no feed for input " + nm);
    check_feed(g, id, f->second, syms);
  }

  // The scratch files: the model, one raw file per input, the request, one per computed output, the result and stderr.
  Scratch s;
  write_file(s.path("model.onnx"), g.to_onnx(computed));
  std::string request;
  int k = 0;
  for (int id : inputs) {
    const Array& feed = feeds.at(g.value(id).name);
    std::string file = "in" + std::to_string(k++) + ".bin";
    write_file(s.path(file), to_bytes(feed));
    request += "input " + file + " " + name(feed.dtype) + " " + std::to_string(feed.shape.size());
    for (int64_t d : feed.shape) request += " " + std::to_string(d);
    request += " " + hex(g.value(id).name) + "\n";
  }
  std::vector<std::string> out_files;
  for (size_t j = 0; j < computed.size(); j++) {
    const hir::Value& v = g.value(computed[j]);
    out_files.push_back("out" + std::to_string(j) + ".bin");
    s.path(out_files.back());
    request += "output " + out_files.back() + " " + name(v.dtype) + " " + hex(v.name) + "\n";
  }
  write_file(s.path("request.txt"), request);
  std::string result_file = s.path("result.txt");
  std::string err_file = s.path("stderr.txt");

  int status = run_helper({python_exe(), helper_script(), s.dir}, err_file);
  if (status != 0)
    throw Error("nfcuop tinygrad: the helper failed (" + python_exe() + " " + helper_script() + " exited " + std::to_string(status) + "): " + stderr_text(err_file));

  // result.txt: one line per computed output, in order, with the shape tinygrad computed.
  std::istringstream lines(read_file(result_file));
  std::string line;
  for (size_t j = 0; j < computed.size(); j++) {
    if (!std::getline(lines, line)) throw Error("nfcuop tinygrad: the helper wrote " + std::to_string(j) + " of " + std::to_string(computed.size()) + " results");
    std::istringstream fs(line);
    std::string file, dt;
    size_t rank = 0;
    fs >> file >> dt >> rank;
    if (!fs || file != out_files[j]) throw Error("nfcuop tinygrad: bad result line \"" + line + "\"");
    Shape shape(rank);
    for (size_t r = 0; r < rank; r++) {
      if (!(fs >> shape[r])) throw Error("nfcuop tinygrad: bad result line \"" + line + "\"");
    }
    const hir::Value& v = g.value(computed[j]);
    DType d = dtype_named(dt);
    if (d != v.dtype || rank != v.shape.size())
      throw Error("nfcuop tinygrad: output " + v.name + " is " + name(d) + " of shape " + to_string(shape) + ", the graph has " + name(v.dtype) + " of rank " + std::to_string(v.shape.size()));
    std::string bytes = read_file(s.dir + "/" + file);
    if (bytes.size() != static_cast<size_t>(numel(shape)) * elem_size(d))
      throw Error("nfcuop tinygrad: output " + v.name + " has " + std::to_string(bytes.size()) + " bytes, its shape " + to_string(shape) + " needs " + std::to_string(static_cast<size_t>(numel(shape)) * elem_size(d)));
    result[slot[j]] = from_bytes(d, shape, bytes);
  }
  return result;
}

}  // namespace tinygrad
}  // namespace nfcuop
