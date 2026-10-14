// nfcuop tinygrad back end (nfcuop_tinygrad.hpp). Two paths with the same results:
//
//   embedded    CPython is loaded with dlopen from the libpython of the interpreter named by NFCUOP_TINYGRAD_PYTHON, started by
//               the first call that can start it, and never finalized. tinygrad and numpy are imported once, and the OnnxRunner
//               of each model is kept. Tensors cross as bytes: numpy.frombuffer going in, ndarray.tobytes coming out.
//   subprocess  the graph and the feeds go to a scratch directory; scripts/tinygrad_run.py runs the model and writes the outputs
//               there, and they are read back here. The file layout is documented in that script. One Python process per call.
//
// The embedded path is taken when the interpreter is (or can be) started on the calling thread and tinygrad imports. Otherwise
// the call takes the subprocess path, and an error from that path says why the embedded one was not used. NFCUOP_TINYGRAD_EMBED=0
// selects the subprocess path.
//
// Interpreter rules (docs/notes/poly.md): one interpreter per process. A libpython that is already loaded and is not the one of
// the executable is refused (the subprocess path is used). When nfcpoly's Python backend started the interpreter first, it is reused
// when the executable's prefix is the same. The GIL stays with the thread that started the interpreter, as in nfcpoly, so the
// embedded path runs on that thread only; a call from another thread takes the subprocess path.
//
// CPython reports errors through return values, never by unwinding, and nothing here lets a C++ exception cross a CPython frame.
// A Python exception becomes an nfcuop::Error whose text is the traceback.
//
// The subprocess path starts the helper with fork and execvp, not through a shell: the arguments are passed as they are, so no
// name or path is quoted or interpolated. Its stderr goes to a file in the scratch directory, which becomes the text of the Error
// on failure. The scratch directory is removed when the call ends, on every path.
#include "nfcuop_tinygrad.hpp"

#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <initializer_list>
#include <map>
#include <memory>
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

// Runs argv (argv[0] is looked up on PATH) with stdout to `out_file` (else /dev/null) and stderr to `err_file`. Returns the exit
// status; a process that cannot be started exits with 127 and says so on stderr.
int run_helper(const std::vector<std::string>& argv, const std::string& err_file, const std::string& out_file = "") {
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
    int ofd = open(out_file.empty() ? "/dev/null" : out_file.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (ofd >= 0) {
      dup2(ofd, 1);
      close(ofd);
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

// The elements of an array in the raw layout of both paths (little endian, Bool one byte).
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

// ---- the embedded interpreter ----

// CPython is not linked. Its entry points are looked up with dlsym in the libpython that belongs to the executable, and this table
// holds the ones used here (all of them exist in CPython 3.12 and 3.13; the signatures are the C API's). A PyObject is only a pointer.
struct PyObj;
typedef ssize_t PySsize;

struct Api {
  void (*Py_SetProgramName)(const wchar_t*);
  void (*Py_InitializeEx)(int);
  int (*Py_IsInitialized)();
  const char* (*Py_GetVersion)();
  wchar_t* (*Py_DecodeLocale)(const char*, size_t*);
  int (*PyGILState_Check)();
  int (*PyGILState_Ensure)();
  void (*PyGILState_Release)(int);
  void (*Py_IncRef)(PyObj*);
  void (*Py_DecRef)(PyObj*);
  PyObj* (*PyImport_ImportModule)(const char*);
  PyObj* (*PyObject_GetAttrString)(PyObj*, const char*);
  PyObj* (*PyObject_CallObject)(PyObj*, PyObj*);
  PyObj* (*PyObject_GetItem)(PyObj*, PyObj*);
  PyObj* (*PyObject_Str)(PyObj*);
  PyObj* (*PyTuple_New)(PySsize);
  int (*PyTuple_SetItem)(PyObj*, PySsize, PyObj*);  // steals the item
  PyObj* (*PySequence_GetItem)(PyObj*, PySsize);
  PySsize (*PySequence_Size)(PyObj*);
  PyObj* (*PyDict_New)();
  int (*PyDict_SetItem)(PyObj*, PyObj*, PyObj*);
  PyObj* (*PyBytes_FromStringAndSize)(const char*, PySsize);
  int (*PyBytes_AsStringAndSize)(PyObj*, char**, PySsize*);
  PyObj* (*PyUnicode_FromString)(const char*);
  const char* (*PyUnicode_AsUTF8)(PyObj*);
  PyObj* (*PyLong_FromLongLong)(long long);
  long long (*PyLong_AsLongLong)(PyObj*);
  PyObj* (*PyErr_Occurred)();
  void (*PyErr_Clear)();
  void (*PyErr_Fetch)(PyObj**, PyObj**, PyObj**);
  void (*PyErr_NormalizeException)(PyObj**, PyObj**, PyObj**);
  int (*PyException_SetTraceback)(PyObj*, PyObj*);
  PyObj* (*PyErr_GetRaisedException)();  // optional (3.12 and newer): when null, PyErr_Fetch is used
};

template <typename F>
bool bind(void* lib, F& fn, const char* name) {
  void* p = dlsym(lib, name);
  if (!p) return false;
  fn = reinterpret_cast<F>(p);
  return true;
}

// Binds the required entry points of Api from `lib`; returns the name of the first one missing, or "".
std::string bind_api(void* lib, Api& a) {
  const char* missing = nullptr;
#define NFCUOP_NEED(f) if (!missing && !bind(lib, a.f, #f)) missing = #f
  NFCUOP_NEED(Py_SetProgramName);
  NFCUOP_NEED(Py_InitializeEx);
  NFCUOP_NEED(Py_IsInitialized);
  NFCUOP_NEED(Py_GetVersion);
  NFCUOP_NEED(Py_DecodeLocale);
  NFCUOP_NEED(PyGILState_Check);
  NFCUOP_NEED(PyGILState_Ensure);
  NFCUOP_NEED(PyGILState_Release);
  NFCUOP_NEED(Py_IncRef);
  NFCUOP_NEED(Py_DecRef);
  NFCUOP_NEED(PyImport_ImportModule);
  NFCUOP_NEED(PyObject_GetAttrString);
  NFCUOP_NEED(PyObject_CallObject);
  NFCUOP_NEED(PyObject_GetItem);
  NFCUOP_NEED(PyObject_Str);
  NFCUOP_NEED(PyTuple_New);
  NFCUOP_NEED(PyTuple_SetItem);
  NFCUOP_NEED(PySequence_GetItem);
  NFCUOP_NEED(PySequence_Size);
  NFCUOP_NEED(PyDict_New);
  NFCUOP_NEED(PyDict_SetItem);
  NFCUOP_NEED(PyBytes_FromStringAndSize);
  NFCUOP_NEED(PyBytes_AsStringAndSize);
  NFCUOP_NEED(PyUnicode_FromString);
  NFCUOP_NEED(PyUnicode_AsUTF8);
  NFCUOP_NEED(PyLong_FromLongLong);
  NFCUOP_NEED(PyLong_AsLongLong);
  NFCUOP_NEED(PyErr_Occurred);
  NFCUOP_NEED(PyErr_Clear);
  NFCUOP_NEED(PyErr_Fetch);
  NFCUOP_NEED(PyErr_NormalizeException);
  NFCUOP_NEED(PyException_SetTraceback);
#undef NFCUOP_NEED
  bind(lib, a.PyErr_GetRaisedException, "PyErr_GetRaisedException");
  return missing ? missing : "";
}

// An owned reference, dropped on every path. The GIL must be held while one is alive (the Gil guard is declared before it).
struct Ref {
  const Api* a;
  PyObj* p;
  Ref(const Api& api, PyObj* o) : a(&api), p(o) {}
  ~Ref() {
    if (p) a->Py_DecRef(p);
  }
  Ref(const Ref&) = delete;
  Ref& operator=(const Ref&) = delete;
  PyObj* get() const { return p; }
  explicit operator bool() const { return p != nullptr; }
  PyObj* release() {
    PyObj* q = p;
    p = nullptr;
    return q;
  }
};

// Holds the GIL for its scope. The embedded path only runs on the thread that holds it, so this is re-entrant there.
struct Gil {
  const Api& a;
  int state;
  explicit Gil(const Api& api) : a(api), state(api.PyGILState_Ensure()) {}
  ~Gil() { a.PyGILState_Release(state); }
  Gil(const Gil&) = delete;
  Gil& operator=(const Gil&) = delete;
};

// The Python exception in the error indicator as text (its traceback, or its str when the traceback cannot be formatted), and the
// indicator cleared. The GIL must be held.
std::string py_error(const Api& a) {
  PyObj* raw = nullptr;
  if (a.PyErr_GetRaisedException) {
    raw = a.PyErr_GetRaisedException();
  } else {
    PyObj *t = nullptr, *v = nullptr, *tb = nullptr;
    a.PyErr_Fetch(&t, &v, &tb);
    a.PyErr_NormalizeException(&t, &v, &tb);
    if (v && tb) a.PyException_SetTraceback(v, tb);
    if (t) a.Py_DecRef(t);
    if (tb) a.Py_DecRef(tb);
    raw = v;
  }
  Ref exc(a, raw);
  if (!exc) {
    a.PyErr_Clear();
    return "(no Python exception was set)";
  }
  std::string text;
  {
    Ref tbmod(a, a.PyImport_ImportModule("traceback"));
    Ref fmt(a, tbmod ? a.PyObject_GetAttrString(tbmod.get(), "format_exception") : nullptr);
    Ref cls(a, a.PyObject_GetAttrString(exc.get(), "__class__"));
    Ref tb(a, a.PyObject_GetAttrString(exc.get(), "__traceback__"));
    if (cls && tb && fmt) {
      PyObj* t = a.PyTuple_New(3);
      if (t) {
        a.Py_IncRef(cls.get());
        a.PyTuple_SetItem(t, 0, cls.get());
        a.Py_IncRef(exc.get());
        a.PyTuple_SetItem(t, 1, exc.get());
        a.Py_IncRef(tb.get());
        a.PyTuple_SetItem(t, 2, tb.get());
      }
      Ref targs(a, t);
      Ref lines(a, targs ? a.PyObject_CallObject(fmt.get(), targs.get()) : nullptr);
      if (lines) {
        PySsize n = a.PySequence_Size(lines.get());
        for (PySsize k = 0; k < n; k++) {
          Ref line(a, a.PySequence_GetItem(lines.get(), k));
          const char* c = line ? a.PyUnicode_AsUTF8(line.get()) : nullptr;
          if (c) text += c;
          else a.PyErr_Clear();
        }
      }
    }
  }
  if (text.empty()) {
    Ref s(a, a.PyObject_Str(exc.get()));
    const char* c = s ? a.PyUnicode_AsUTF8(s.get()) : nullptr;
    if (c) text = c;
  }
  a.PyErr_Clear();
  while (!text.empty() && (text.back() == '\n' || text.back() == ' ')) text.pop_back();
  return text.empty() ? "(an exception with no text)" : text;
}

// Raises the error of the failed Python step `what`. The GIL must be held (the caller's guard releases it on the way out).
[[noreturn]] void fail_py(const Api& a, const std::string& what) {
  throw Error("nfcuop tinygrad: " + what + ": " + py_error(a));
}

// `p` as it is, or the error of the failed step `what`. p is a new reference.
PyObj* ok(const Api& a, PyObj* p, const char* what) {
  if (!p) fail_py(a, what);
  return p;
}

// A new tuple of `items` (their references are not stolen); null with an error set when it cannot be made.
PyObj* make_tuple(const Api& a, std::initializer_list<PyObj*> items) {
  PyObj* t = a.PyTuple_New(static_cast<PySsize>(items.size()));
  if (!t) return nullptr;
  PySsize k = 0;
  for (PyObj* x : items) {
    a.Py_IncRef(x);
    a.PyTuple_SetItem(t, k++, x);
  }
  return t;
}

// fn(args...), a new reference or null with an error set.
PyObj* call(const Api& a, PyObj* fn, std::initializer_list<PyObj*> args) {
  Ref t(a, make_tuple(a, args));
  if (!t) return nullptr;
  return a.PyObject_CallObject(fn, t.get());
}

// obj.name(args...), a new reference or null with an error set.
PyObj* method(const Api& a, PyObj* obj, const char* name, std::initializer_list<PyObj*> args) {
  Ref f(a, a.PyObject_GetAttrString(obj, name));
  if (!f) return nullptr;
  return call(a, f.get(), args);
}

// The tuple of a shape of ints (new reference).
PyObj* shape_tuple(const Api& a, const Shape& s) {
  Ref t(a, ok(a, a.PyTuple_New(static_cast<PySsize>(s.size())), "cannot make a shape tuple"));
  for (size_t k = 0; k < s.size(); k++) {
    Ref x(a, ok(a, a.PyLong_FromLongLong(static_cast<long long>(s[k])), "cannot make a shape tuple"));
    a.PyTuple_SetItem(t.get(), static_cast<PySsize>(k), x.release());  // steals
  }
  return t.release();
}

// A started interpreter of this process. It is never finalized, and it is reached only from the thread that holds its GIL.
struct Interp {
  Api api{};
  std::string exe;                          // the Python executable that started it
  bool started_here = false;                // this backend started it (not nfcpoly or another caller)
  bool imported = false;
  PyObj* np = nullptr;                      // numpy
  PyObj* Tensor = nullptr;                  // tinygrad.Tensor
  PyObj* OnnxRunner = nullptr;              // tinygrad.nn.onnx.OnnxRunner
  std::map<std::string, PyObj*> runners;    // OnnxRunner per model and symbol binding (runner_for); kept for the process
};

Interp* g_interp = nullptr;
Path g_last = Path::None;
std::string g_status;  // why the last embedded() call did not give the embedded path ("" when it did)
Counts g_counts;

// What the helper's interpreter reports about itself, one value per line: the executable as it names itself, its prefix, the
// shared library's file name and directory (sysconfig), the library's install name, and major.minor.
struct PyInfo {
  std::string executable, prefix, ldlibrary, libdir, instsoname, major_minor;
};

const char* const kQuery =
    "import sys, sysconfig; print(sys.executable); print(sys.prefix); print(sysconfig.get_config_var('LDLIBRARY')); "
    "print(sysconfig.get_config_var('LIBDIR')); print(sysconfig.get_config_var('INSTSONAME')); print('%d.%d' % sys.version_info[:2])";

bool query_python(const std::string& exe, PyInfo* info, std::string* why) {
  Scratch s;
  std::string err = s.path("query-stderr.txt");
  std::string out = s.path("query-stdout.txt");
  int status = run_helper({exe, "-c", kQuery}, err, out);
  if (status != 0) {
    *why = "cannot ask " + exe + " for its libpython (exited " + std::to_string(status) + "): " + stderr_text(err);
    return false;
  }
  std::istringstream in(read_file(out));
  std::vector<std::string> lines;
  for (std::string line; std::getline(in, line);) lines.push_back(line);
  if (lines.size() != 6) {
    *why = "cannot read the answer of " + exe + " about its libpython";
    return false;
  }
  auto value = [](const std::string& v) { return v == "None" ? std::string() : v; };
  info->executable = lines[0];
  info->prefix = lines[1];
  info->ldlibrary = value(lines[2]);
  info->libdir = value(lines[3]);
  info->instsoname = value(lines[4]);
  info->major_minor = lines[5];
  return true;
}

std::string dl_error() {
  const char* e = dlerror();
  return e ? e : "unknown error";
}

// Opens the shared libpython of the interpreter: NFCUOP_TINYGRAD_LIBPYTHON when set, else the install name and then the link name
// in its LIBDIR. RTLD_GLOBAL, because the extension modules that Python loads (numpy, ...) bind to the Py* symbols of the process.
// When the process already has a libpython (nfcpoly's, say), only that same file is accepted, and it is never loaded a second time:
// a second copy would put two sets of Py* symbols in one process.
void* open_libpython(const PyInfo& info, std::string* why) {
  std::vector<std::string> candidates;
  if (const char* p = std::getenv("NFCUOP_TINYGRAD_LIBPYTHON"); p && *p) {
    candidates.push_back(p);
  } else {
    for (const std::string* f : {&info.instsoname, &info.ldlibrary}) {
      bool static_lib = f->size() >= 2 && f->compare(f->size() - 2, 2, ".a") == 0;
      if (f->empty() || static_lib || info.libdir.empty()) continue;
      std::string path = info.libdir + "/" + *f;
      if (std::find(candidates.begin(), candidates.end(), path) == candidates.end()) candidates.push_back(path);
    }
    if (candidates.empty()) {
      *why = "the interpreter has no shared libpython (Py_ENABLE_SHARED is 0); set NFCUOP_TINYGRAD_LIBPYTHON to one";
      return nullptr;
    }
  }
  void* loaded = dlsym(RTLD_DEFAULT, "Py_IsInitialized");  // a libpython the process already has, if any
  std::string errs;
  for (const std::string& path : candidates) {
    if (loaded) {
      void* same = dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD);  // a handle only when this file is loaded already
      if (same && dlsym(same, "Py_IsInitialized") == loaded) return same;
      *why = "another libpython is already loaded in this process, not the one of " + info.executable;
      return nullptr;
    }
    if (void* h = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL)) return h;
    errs += "; " + dl_error();
  }
  *why = "cannot load libpython" + errs;
  return nullptr;
}

void run_exit_callbacks();  // at exit: see below

// Starts the interpreter of `exe` on the calling thread, if it is not started, and checks that it is the executable's. Returns null
// with `why` when that cannot be done; nothing is kept then, so the next call tries again.
Interp* start(const std::string& exe, std::string* why) {
  PyInfo info;
  if (!query_python(exe, &info, why)) return nullptr;
  void* lib = open_libpython(info, why);
  if (!lib) return nullptr;
  std::unique_ptr<Interp> in(new Interp());
  in->exe = exe;
  if (std::string missing = bind_api(lib, in->api); !missing.empty()) {
    *why = "the library " + info.libdir + " has no " + missing + ": it is not a CPython library";
    return nullptr;
  }
  const Api& a = in->api;
  std::string version = a.Py_GetVersion();  // a static string: allowed before initialization
  std::string want = info.major_minor + ".";
  if (version.compare(0, want.size(), want) != 0) {
    *why = "libpython is " + version.substr(0, version.find(' ')) + " but " + exe + " is " + info.major_minor;
    return nullptr;
  }
  const bool started_here = !a.Py_IsInitialized();
  if (started_here) {
    // The program name is the executable's, so that CPython finds its prefix (and a venv's pyvenv.cfg) as the executable does.
    // The string is kept for the life of the process, as Py_SetProgramName requires.
    wchar_t* prog = a.Py_DecodeLocale(info.executable.c_str(), nullptr);
    if (!prog) {
      *why = "cannot decode " + info.executable;
      return nullptr;
    }
    a.Py_SetProgramName(prog);
    a.Py_InitializeEx(0);  // no signal handlers: the host keeps its own
  }
  if (!a.Py_IsInitialized()) {
    *why = "Py_InitializeEx did not start the interpreter";
    return nullptr;
  }
  if (!a.PyGILState_Check()) {
    *why = "the interpreter in this process belongs to another thread";
    return nullptr;
  }
  {
    Gil gil(a);
    Ref sys(a, a.PyImport_ImportModule("sys"));
    Ref pre(a, sys ? a.PyObject_GetAttrString(sys.get(), "prefix") : nullptr);
    const char* got = pre ? a.PyUnicode_AsUTF8(pre.get()) : nullptr;
    if (!got) {
      *why = "cannot read sys.prefix of the embedded interpreter: " + py_error(a);
      return nullptr;
    }
    if (info.prefix != got) {
      *why = "the embedded interpreter has the prefix " + std::string(got) + ", the executable has " + info.prefix;
      return nullptr;
    }
  }
  in->started_here = started_here;
  static bool registered = false;
  if (!registered) {
    std::atexit(run_exit_callbacks);
    registered = true;
  }
  return in.release();
}

// Runs at exit (std::atexit, registered when an interpreter starts). An interpreter this backend started is never finalized, so the
// atexit callbacks that Py_Finalize would run do not run. tinygrad's worker pool (parallel compilation, spawned on first use) and the
// multiprocessing finalizers that release its semaphores are among them, and without them the resource tracker reports the
// semaphores at exit. So the callbacks are run here, on the thread that holds the GIL, and only for an interpreter this backend started
// (one that nfcpoly started is left as it is).
void run_exit_callbacks() {
  Interp* in = g_interp;
  if (!in || !in->started_here || !in->api.PyGILState_Check()) return;
  const Api& a = in->api;
  Gil gil(a);
  Ref atexit_mod(a, a.PyImport_ImportModule("atexit"));
  Ref run(a, atexit_mod ? a.PyObject_GetAttrString(atexit_mod.get(), "_run_exitfuncs") : nullptr);
  Ref done(a, run ? call(a, run.get(), {}) : nullptr);
  if (!done) a.PyErr_Clear();
}

// Imports numpy and tinygrad once (failures are not kept: the next call imports again).
bool import_modules(Interp* in, std::string* why) {
  const Api& a = in->api;
  Gil gil(a);
  try {
    Ref np(a, ok(a, a.PyImport_ImportModule("numpy"), "cannot import numpy"));
    Ref tg(a, ok(a, a.PyImport_ImportModule("tinygrad"), "cannot import tinygrad"));
    Ref tensor(a, ok(a, a.PyObject_GetAttrString(tg.get(), "Tensor"), "tinygrad has no Tensor"));
    Ref onnx(a, ok(a, a.PyImport_ImportModule("tinygrad.nn.onnx"), "cannot import tinygrad.nn.onnx"));
    Ref runner(a, ok(a, a.PyObject_GetAttrString(onnx.get(), "OnnxRunner"), "tinygrad.nn.onnx has no OnnxRunner"));
    in->np = np.release();
    in->Tensor = tensor.release();
    in->OnnxRunner = runner.release();
  } catch (const Error& e) {
    *why = e.what();
    return false;
  }
  in->imported = true;
  g_counts.imports++;
  return true;
}

// The embedded interpreter with tinygrad imported, on the calling thread; null when this call cannot use it, with `why`. Sets g_status.
Interp* embedded(std::string* why) {
  Interp* in = nullptr;
  std::string reason;
  const char* off = std::getenv("NFCUOP_TINYGRAD_EMBED");
  const std::string exe = python_exe();
  if (off && std::strcmp(off, "0") == 0) {
    reason = "NFCUOP_TINYGRAD_EMBED=0";
  } else if (g_interp && exe != g_interp->exe) {
    reason = "this process runs the interpreter " + g_interp->exe + ", not " + exe;
  } else {
    in = g_interp ? g_interp : start(exe, &reason);  // start() keeps nothing on failure, so the next call tries again
    if (in && !g_interp) g_interp = in;
    if (in && !in->api.PyGILState_Check()) {
      reason = "the embedded interpreter runs on the thread that started it";
      in = nullptr;
    }
    if (in && !in->imported && !import_modules(in, &reason)) in = nullptr;
  }
  if (!in) *why = reason;
  g_status = in ? "" : reason;
  return in;
}

// The OnnxRunner of `model` (ONNX bytes): built on first use, kept after that. The model is handed over as a uint8 Tensor, which
// OnnxPBParser reads, so no file is written. The returned reference belongs to the cache.
// A runner is kept per model and per binding of its symbols: tinygrad's runner fixes each symbol to the size of the first feed that
// has it (OnnxRunner.variable_dims), so a runner built for one batch size rejects another. A static model has one runner.
PyObj* runner_for(Interp* in, const std::string& model, const std::map<std::string, int64_t>& syms) {
  std::string key = model + '\0';
  for (const auto& kv : syms) key += kv.first + "=" + std::to_string(kv.second) + ";";
  auto it = in->runners.find(key);
  if (it != in->runners.end()) return it->second;
  const Api& a = in->api;
  Gil gil(a);
  Ref raw(a, ok(a, a.PyBytes_FromStringAndSize(model.data(), static_cast<PySsize>(model.size())), "cannot make the model bytes"));
  Ref u8(a, ok(a, a.PyUnicode_FromString("uint8"), "cannot make the dtype name"));
  Ref flat(a, ok(a, method(a, in->np, "frombuffer", {raw.get(), u8.get()}), "numpy.frombuffer failed"));
  Ref own(a, ok(a, method(a, flat.get(), "copy", {}), "numpy copy failed"));
  Ref tensor(a, ok(a, call(a, in->Tensor, {own.get()}), "tinygrad.Tensor failed on the model"));
  Ref runner(a, ok(a, call(a, in->OnnxRunner, {tensor.get()}), "tinygrad OnnxRunner failed on the model"));
  a.Py_IncRef(runner.get());  // the cache's reference
  in->runners[key] = runner.get();
  g_counts.runners++;
  return runner.get();
}

// The embedded run of the plan: the feeds become Tensors of numpy arrays built from their bytes, the runner is called on them, and
// each computed output comes back as bytes with the shape tinygrad computed. Python errors are the Error's text (the traceback).
std::vector<Array> run_embedded(Interp* in, const hir::Graph& g, const std::vector<int>& computed, const std::vector<size_t>& slot,
                                const std::vector<int>& inputs, const std::map<std::string, int64_t>& syms,
                                const std::map<std::string, Array>& feeds, std::vector<Array> result) {
  const Api& a = in->api;
  Gil gil(a);
  PyObj* runner = runner_for(in, g.to_onnx(computed), syms);
  Ref fd(a, ok(a, a.PyDict_New(), "cannot make the feed dictionary"));
  for (int id : inputs) {
    const hir::Value& v = g.value(id);
    const Array& feed = feeds.at(v.name);
    std::string bytes = to_bytes(feed);
    Ref raw(a, ok(a, a.PyBytes_FromStringAndSize(bytes.data(), static_cast<PySsize>(bytes.size())), "cannot make the input bytes"));
    Ref dt(a, ok(a, a.PyUnicode_FromString(name(feed.dtype)), "cannot make the dtype name"));
    Ref flat(a, ok(a, method(a, in->np, "frombuffer", {raw.get(), dt.get()}), "numpy.frombuffer failed"));
    Ref own(a, ok(a, method(a, flat.get(), "copy", {}), "numpy copy failed"));
    Ref sh(a, shape_tuple(a, feed.shape));
    Ref arr(a, ok(a, method(a, own.get(), "reshape", {sh.get()}), "numpy reshape failed"));
    Ref t(a, ok(a, call(a, in->Tensor, {arr.get()}), "tinygrad.Tensor failed on a feed"));
    Ref key(a, ok(a, a.PyUnicode_FromString(v.name.c_str()), "cannot make the input name"));
    if (a.PyDict_SetItem(fd.get(), key.get(), t.get()) != 0) fail_py(a, "cannot store feed " + v.name);
  }
  Ref res(a, ok(a, call(a, runner, {fd.get()}), "the model failed"));
  for (size_t j = 0; j < computed.size(); j++) {
    const hir::Value& v = g.value(computed[j]);
    Ref key(a, ok(a, a.PyUnicode_FromString(v.name.c_str()), "cannot make the output name"));
    Ref item(a, a.PyObject_GetItem(res.get(), key.get()));
    if (!item) fail_py(a, "the run returned no output " + v.name);
    Ref npv(a, ok(a, method(a, item.get(), "numpy", {}), "tinygrad output has no numpy()"));
    Ref arr(a, ok(a, method(a, in->np, "asarray", {npv.get()}), "numpy.asarray failed"));
    Ref dt(a, ok(a, a.PyObject_GetAttrString(arr.get(), "dtype"), "output has no dtype"));
    Ref dn(a, ok(a, a.PyObject_GetAttrString(dt.get(), "name"), "output dtype has no name"));
    const char* dname = a.PyUnicode_AsUTF8(dn.get());
    if (!dname) fail_py(a, "output dtype name is not text");
    std::string got_dtype = dname;
    Ref sh(a, ok(a, a.PyObject_GetAttrString(arr.get(), "shape"), "output has no shape"));
    PySsize rank = a.PySequence_Size(sh.get());
    if (rank < 0) fail_py(a, "output shape is not a sequence");
    Shape shape(static_cast<size_t>(rank));
    for (PySsize k = 0; k < rank; k++) {
      Ref e(a, ok(a, a.PySequence_GetItem(sh.get(), k), "output shape item"));
      long long x = a.PyLong_AsLongLong(e.get());
      if (x == -1 && a.PyErr_Occurred()) fail_py(a, "output shape item is not an int");
      shape[static_cast<size_t>(k)] = x;
    }
    if (got_dtype != name(v.dtype) || static_cast<size_t>(rank) != v.shape.size())
      throw Error("nfcuop tinygrad: output " + v.name + " is " + got_dtype + " of shape " + to_string(shape) + ", the graph has " + name(v.dtype) + " of rank " + std::to_string(v.shape.size()));
    Ref bo(a, ok(a, method(a, arr.get(), "tobytes", {}), "output has no tobytes()"));
    char* data = nullptr;
    PySsize n = 0;
    if (a.PyBytes_AsStringAndSize(bo.get(), &data, &n) != 0) fail_py(a, "output bytes");
    std::string bytes(data, static_cast<size_t>(n));
    if (bytes.size() != static_cast<size_t>(numel(shape)) * elem_size(v.dtype))
      throw Error("nfcuop tinygrad: output " + v.name + " has " + std::to_string(bytes.size()) + " bytes, its shape " + to_string(shape) + " needs " + std::to_string(static_cast<size_t>(numel(shape)) * elem_size(v.dtype)));
    result[slot[j]] = from_bytes(v.dtype, shape, bytes);
  }
  return result;
}

// ---- the subprocess path ----

// The helper's run of the plan: the model, one raw file per input, the request, one per computed output, the result and stderr.
// `embedded_why` says why the embedded path was not used; it is added to the error text.
std::vector<Array> run_subprocess(const hir::Graph& g, const std::vector<int>& computed, const std::vector<size_t>& slot,
                                  const std::vector<int>& inputs, const std::map<std::string, Array>& feeds, std::vector<Array> result,
                                  const std::string& embedded_why) {
  const std::string note = embedded_why.empty() ? "" : "; the embedded interpreter was not used: " + embedded_why;
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
  g_counts.subprocess_runs++;
  if (status != 0)
    throw Error("nfcuop tinygrad: the helper failed (" + python_exe() + " " + helper_script() + " exited " + std::to_string(status) + "): " + stderr_text(err_file) + note);

  // result.txt: one line per computed output, in order, with the shape tinygrad computed.
  std::istringstream lines(read_file(result_file));
  std::string line;
  for (size_t j = 0; j < computed.size(); j++) {
    if (!std::getline(lines, line)) throw Error("nfcuop tinygrad: the helper wrote " + std::to_string(j) + " of " + std::to_string(computed.size()) + " results" + note);
    std::istringstream fs(line);
    std::string file, dt;
    size_t rank = 0;
    fs >> file >> dt >> rank;
    if (!fs || file != out_files[j]) throw Error("nfcuop tinygrad: bad result line \"" + line + "\"" + note);
    Shape shape(rank);
    for (size_t r = 0; r < rank; r++) {
      if (!(fs >> shape[r])) throw Error("nfcuop tinygrad: bad result line \"" + line + "\"" + note);
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

// ---- the plan shared by both paths ----

struct Plan {
  std::vector<Array> result;     // the outputs that are inputs or initializers, already set
  std::vector<int> computed;     // the other outputs, in request order
  std::vector<size_t> slot;      // where each computed output goes in result
  std::vector<int> inputs;       // the graph inputs the computed outputs depend on, in id order (Graph::to_onnx writes exactly these)
  std::map<std::string, int64_t> syms;  // the size of each symbol of those inputs, from the feeds
};

// Checks the feeds against the graph and sorts the outputs. Throws Error for a feed that does not fit or is missing.
Plan plan_run(const hir::Graph& g, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds) {
  Plan p;
  p.result.resize(outputs.size());
  // Outputs that are inputs or initializers are returned directly; the others are computed by the exported model.
  for (size_t k = 0; k < outputs.size(); k++) {
    int o = outputs[k];
    if (g.producer(o) >= 0) {
      p.computed.push_back(o);
      p.slot.push_back(k);
    } else if (const Array* a = g.initializer(o)) {
      p.result[k] = *a;
    } else {
      auto f = feeds.find(g.value(o).name);
      if (f == feeds.end()) throw Error("nfcuop tinygrad: no feed for input " + g.value(o).name);
      std::map<std::string, int64_t> syms;
      check_feed(g, o, f->second, syms);
      p.result[k] = f->second;
    }
  }
  if (p.computed.empty()) return p;

  std::set<int> seen, inputs;
  std::vector<int> stack = p.computed;
  while (!stack.empty()) {
    int v = stack.back();
    stack.pop_back();
    if (!seen.insert(v).second) continue;
    int prod = g.producer(v);
    if (prod < 0) {
      if (!g.initializer(v)) inputs.insert(v);
      continue;
    }
    for (int in : g.nodes()[static_cast<size_t>(prod)].inputs)
      if (in >= 0) stack.push_back(in);
  }
  for (int id : inputs) {
    const std::string& nm = g.value(id).name;
    auto f = feeds.find(nm);
    if (f == feeds.end()) throw Error("nfcuop tinygrad: no feed for input " + nm);
    check_feed(g, id, f->second, p.syms);
  }
  p.inputs.assign(inputs.begin(), inputs.end());
  return p;
}

}  // namespace

Path last_path() { return g_last; }
std::string embedded_status() { return g_status; }
Counts counts() { return g_counts; }

bool available(std::string* why) {
  std::string embedded_why;
  if (embedded(&embedded_why)) return true;
  Scratch s;
  std::string err = s.path("stderr.txt");
  int status = run_helper({python_exe(), helper_script(), "--check"}, err);
  if (status == 0) return true;
  if (why) {
    *why = "tinygrad is not available (" + python_exe() + " exited " + std::to_string(status) + "): " + stderr_text(err);
    if (!embedded_why.empty()) *why += "; the embedded interpreter was not used: " + embedded_why;
  }
  return false;
}

std::vector<Array> run(const hir::Graph& g, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds) {
  Plan p = plan_run(g, outputs, feeds);
  if (p.computed.empty()) {
    g_last = Path::None;
    return std::move(p.result);
  }
  std::string why;
  if (Interp* in = embedded(&why)) {
    g_last = Path::Embedded;
    std::vector<Array> out = run_embedded(in, g, p.computed, p.slot, p.inputs, p.syms, feeds, std::move(p.result));
    g_counts.embedded_runs++;
    return out;
  }
  g_last = Path::Subprocess;
  return run_subprocess(g, p.computed, p.slot, p.inputs, feeds, std::move(p.result), why);
}

}  // namespace tinygrad
}  // namespace nfcuop
