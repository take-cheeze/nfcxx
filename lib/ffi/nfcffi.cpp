// nfcffi implementation. See nfcffi.hpp and docs/notes/ffi.md. The driver lookup, hashing, cache directory, child process and
// the file helpers are nfceval's (lib/eval/nfceval_build.hpp), so both libraries compile the same way.
#include "nfcffi.hpp"

#include <dlfcn.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <exception>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>

#include "../eval/nfceval_build.hpp"

#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void*)0)
#endif

namespace nfcffi {

namespace build = nfceval::build;

void* process_symbol(const std::string& name) {
  ::dlerror();
  void* s = ::dlsym(RTLD_DEFAULT, name.c_str());
  if (!s) throw Error("nfcffi: no function '" + name + "' in the running program or the C library");
  return s;
}

Module& Module::operator=(Module&& other) noexcept {
  if (this != &other) {
    if (handle_) ::dlclose(handle_);
    handle_ = other.handle_;
    other.handle_ = nullptr;
  }
  return *this;
}

Module::~Module() {
  if (handle_) ::dlclose(handle_);
}

void* Module::symbol(const std::string& name) const {
  if (!handle_) throw Error("nfcffi: the module is empty");
  ::dlerror();
  void* s = ::dlsym(handle_, name.c_str());
  if (!s) throw Error("nfcffi: the module has no symbol '" + name + "'");
  return s;
}

Ffi::Ffi(std::string driver)
    : driver_(driver.empty() ? build::default_driver(__FILE__) : std::move(driver)),
      cache_(build::default_cache_dir("NFCFFI_CACHE", "nfcffi-cache")),
      decl_tool_(build::repo_root_of(__FILE__) + "/scripts/libclang-cursors") {}

Ffi& Ffi::set_decl_tool(std::string path) {
  decl_tool_ = std::move(path);
  return *this;
}

std::string Declaration::param_decl(std::size_t i, const std::string& name) const {
  std::string t = params.at(i);
  std::string out;
  for (std::size_t k = 0; k < t.size(); ++k) {
    if (t[k] == '@') {
      out += name;
    } else {
      out += t[k];
    }
  }
  while (!out.empty() && out.back() == ' ') out.pop_back();
  return out;
}

namespace {

std::vector<std::string> split_tabs(const std::string& line) {
  std::vector<std::string> out;
  std::size_t s = 0;
  for (;;) {
    std::size_t t = line.find('\t', s);
    out.push_back(line.substr(s, t == std::string::npos ? std::string::npos : t - s));
    if (t == std::string::npos) break;
    s = t + 1;
  }
  return out;
}

// The abstract form of a signature type: "@" removed, trailing blanks dropped.
std::string abstract_type(const std::string& t) {
  std::string out;
  for (char c : t) {
    if (c != '@') out += c;
  }
  while (!out.empty() && out.back() == ' ') out.pop_back();
  return out;
}

}  // namespace

std::vector<Declaration> Ffi::declarations(const std::string& file, Dialect dialect) const {
  // The tool's output goes to a log in the cache directory: the directory must exist before the tool runs.
  std::string err = build::ensure_cache_dir(cache_);
  if (!err.empty()) throw Error("nfcffi: " + err);

  // Every file the source includes, not only the primary one: the front end reads NFCXX_DECL_ALL.
  std::vector<std::string> args{"/bin/sh", "-c", "NFCXX_DECL_ALL=1 exec \"$0\" \"$@\"", decl_tool_};
  if (dialect == Dialect::C) args.push_back("--c");
  args.push_back(file);
  std::string log = cache_ + "/nfcffi-decls-" + build::hash_hex(file) + ".log";
  int status = 0;
  std::string out = build::run_driver(args, log, timeout_, status);
  if (status != 0) {
    if (status == 2 || status == 127 || status == -2)
      throw Error("nfcffi: cannot run the declaration tool '" + decl_tool_ +
                  "' (build it with scripts/setup-libclang-edg.sh): " + out);
    throw CompileError("nfcffi: " + file + " does not parse\n" + out);
  }

  // Records (be/nfcxx_decl.c): "function ID PARENT LINE COL NAME" and "sig ID RETURN VARIADIC PARAM...". Only free functions
  // (parent 0) have signatures; diagnostics on the same stream are skipped.
  std::vector<Declaration> decls;
  std::map<std::string, std::size_t> index;  // record id -> position in decls
  std::size_t pos = 0;
  while (pos < out.size()) {
    std::size_t nl = out.find('\n', pos);
    std::string line = out.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
    pos = nl == std::string::npos ? out.size() : nl + 1;
    std::vector<std::string> f = split_tabs(line);
    if (f.size() >= 6 && f[0] == "function" && f[2] == "0") {
      Declaration d;
      d.name = f[5];
      index[f[1]] = decls.size();
      decls.push_back(d);
    } else if (f.size() >= 4 && f[0] == "sig" && index.count(f[1])) {
      Declaration& d = decls[index[f[1]]];
      d.return_type = abstract_type(f[2]);
      d.variadic = f[3] == "1";
      for (std::size_t k = 4; k < f.size(); ++k) d.params.push_back(f[k]);
    } else if (f.size() >= 6 && f[0] == "cb" && index.count(f[1])) {
      Declaration& d = decls[index[f[1]]];
      Declaration::Callback cb;
      cb.index = std::strtoul(f[2].c_str(), nullptr, 10);
      cb.return_type = abstract_type(f[3]);
      cb.return_kind = f[4].empty() ? 'x' : f[4][0];
      cb.param_kinds = f[5];
      for (std::size_t k = 6; k < f.size(); ++k) cb.params.push_back(f[k]);
      d.callbacks.push_back(cb);
    } else if (f.size() >= 3 && f[0] == "kinds" && index.count(f[1])) {
      Declaration& d = decls[index[f[1]]];
      d.return_kind = f[2].empty() ? 'x' : f[2][0];
      d.param_kinds = f.size() >= 4 ? f[3] : std::string();
    }
  }

  // Keep the functions with a signature; a name declared more than once is an overload set (C++ headers).
  std::vector<Declaration> with_sig;
  for (Declaration& d : decls) {
    if (d.return_type.empty()) continue;
    for (const Declaration& o : decls) {
      if (&o != &d && o.name == d.name) d.overloaded = true;
    }
    with_sig.push_back(d);
  }
  std::map<std::string, int> overload_count;
  for (Declaration& d : with_sig) {
    d.id = d.overloaded ? d.name + "_" + std::to_string(overload_count[d.name]++) : d.name;
  }
  return with_sig;
}

Ffi& Ffi::add_flag(std::string flag) {
  flags_.push_back(std::move(flag));
  return *this;
}

Ffi& Ffi::set_cache_dir(std::string dir) {
  cache_ = std::move(dir);
  return *this;
}

Ffi& Ffi::set_compile_timeout(unsigned seconds) {
  timeout_ = seconds;
  return *this;
}

Module Ffi::compile(const std::string& source, bool cxx) const {
  std::string err = build::ensure_cache_dir(cache_);
  if (!err.empty()) throw Error("nfcffi: " + err);

  // The key covers everything that changes the object: the source, the driver, the flags and the back end.
  std::string key_text = source + '\0' + driver_ + '\0';
  for (const std::string& f : flags_) key_text += f + '\0';
  if (const char* be = std::getenv("NFCXX_BACKEND")) key_text += be;
  if (cxx) key_text += "\nc++";
  std::string base = cache_ + "/nfcffi-" + build::hash_hex(key_text);
  std::string so = base + ".so";

  if (!build::file_exists(so)) {
    std::string c_file = base + (cxx ? ".cpp" : ".c");
    if (!build::write_file(c_file, source)) throw Error("nfcffi: cannot write " + c_file);

    // Built under a temporary name and renamed, so a concurrent reader never sees a partial object.
    std::string tmp = so + ".tmp." + std::to_string((long)::getpid());
    std::vector<std::string> args{driver_, "-shared"};
    args.insert(args.end(), flags_.begin(), flags_.end());
    args.push_back(c_file);
    args.push_back("-o");
    args.push_back(tmp);

    int status = 0;
    std::string out = build::run_driver(args, base + ".log", timeout_, status);
    if (status != 0) {
      throw CompileError("nfcffi: " + build::failure_reason(status, driver_, timeout_) + "\n" + out);
    }
    if (::rename(tmp.c_str(), so.c_str()) != 0) {
      ::unlink(tmp.c_str());
      throw Error("nfcffi: cannot install " + so + ": " + std::strerror(errno));
    }
  }

  void* h = ::dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    const char* e = ::dlerror();
    throw Error(std::string("nfcffi: dlopen failed: ") + (e ? e : "?"));
  }
  return Module(h);
}

}  // namespace nfcffi

namespace nfcffi {

Value Value::of_signed(long long v) {
  Value r;
  r.kind_ = Kind::Signed;
  r.s_ = v;
  return r;
}

Value Value::of_unsigned(unsigned long long v) {
  Value r;
  r.kind_ = Kind::Unsigned;
  r.u_ = v;
  return r;
}

Value Value::of_float(double v) {
  Value r;
  r.kind_ = Kind::Float;
  r.f_ = v;
  return r;
}

Value Value::of_pointer(const void* p) {
  Value r;
  r.kind_ = Kind::Pointer;
  r.p_ = p;
  return r;
}

namespace {

[[noreturn]] void wrong_kind(const char* want) {
  throw Error(std::string("nfcffi: value is not ") + want);
}

}  // namespace

long long Value::as_signed() const {
  if (kind_ != Kind::Signed) wrong_kind("a signed integer");
  return s_;
}

unsigned long long Value::as_unsigned() const {
  if (kind_ != Kind::Unsigned) wrong_kind("an unsigned integer");
  return u_;
}

double Value::as_float() const {
  if (kind_ != Kind::Float) wrong_kind("a float");
  return f_;
}

const void* Value::as_pointer() const {
  if (kind_ != Kind::Pointer) wrong_kind("a pointer");
  return p_;
}

Value Value::of_callable(CallableFn fn) {
  Value r;
  r.kind_ = Kind::Callable;
  r.fn_ = std::make_shared<CallableFn>(std::move(fn));
  return r;
}

const CallableFn& Value::as_callable() const {
  if (kind_ != Kind::Callable) wrong_kind("a host callable");
  return *fn_;
}

Value Value::of_bytes(const void* p, std::size_t n) {
  Value r;
  r.kind_ = Kind::Bytes;
  const unsigned char* b = static_cast<const unsigned char*>(p);
  r.b_.assign(b, b + n);
  return r;
}

const std::vector<unsigned char>& Value::as_bytes() const {
  if (kind_ != Kind::Bytes) wrong_kind("a struct or union (bytes)");
  return b_;
}

namespace {

// A function can be called by name when its declaration has no variadic part, is not overloaded, and passes only
// integers, floats, pointers, structs and unions (void as the result).
const Declaration::Callback* callback_at(const Declaration& d, std::size_t i) {
  for (const Declaration::Callback& cb : d.callbacks) {
    if (cb.index == i) return &cb;
  }
  return nullptr;
}

bool passable(const Declaration& d) {
  if (d.variadic) return false;
  if (d.return_kind == 'x' || std::strchr("iufpvs", d.return_kind) == nullptr) return false;
  if (d.param_kinds.size() != d.params.size()) return false;
  for (std::size_t i = 0; i < d.param_kinds.size(); ++i) {
    char k = d.param_kinds[i];
    if (k == 'c') {
      if (callback_at(d, i) == nullptr) return false;
      continue;
    }
    if (k == 'v' || k == 'x' || std::strchr("iufps", k) == nullptr) return false;
  }
  return true;
}

// The names of the callback context and trampoline of parameter I of D (generated with the wrappers).
std::string callback_context(const Declaration& d, std::size_t i) { return "nfcffi_cbctx_" + d.id + "_" + std::to_string(i); }
std::string callback_trampoline(const Declaration& d, std::size_t i) { return "nfcffi_tramp_" + d.id + "_" + std::to_string(i); }
std::string callback_raw(const Declaration& d, std::size_t i) { return "nfcffi_cbraw_" + d.id + "_" + std::to_string(i); }

// C++ wrappers are extern "C", so that dlsym finds them by their names.
std::string linkage(bool cxx) { return cxx ? "extern \"C\" " : ""; }

// The size of a value of KIND and abstract TYPE: sizeof for a struct or union, else 0.
std::string struct_size(char kind, const std::string& type) {
  return kind == 's' ? "sizeof(" + abstract_type(type) + ")" : "0";
}

// The layout function for D: void nfcffi_layout_NAME(unsigned long *s) stores the size of the result type at s[0] and of
// parameter i at s[i + 1]; 0 for the types that are not structs or unions. Then, for each callback in order, the sizes of
// its result and its parameters (see layout_slots).
std::string layout_text(const Declaration& d, bool cxx) {
  std::string body = "  s[0] = " + struct_size(d.return_kind, d.return_type) + ";\n";
  for (std::size_t i = 0; i < d.params.size(); ++i) {
    body += "  s[" + std::to_string(i + 1) + "] = " + struct_size(d.param_kinds[i], d.params[i]) + ";\n";
  }
  std::size_t next = d.params.size() + 1;
  for (const Declaration::Callback& cb : d.callbacks) {
    body += "  s[" + std::to_string(next++) + "] = " + struct_size(cb.return_kind, cb.return_type) + ";\n";
    for (std::size_t j = 0; j < cb.params.size(); ++j) {
      body += "  s[" + std::to_string(next++) + "] = " + struct_size(cb.param_kinds[j], cb.params[j]) + ";\n";
    }
  }
  return linkage(cxx) + "void nfcffi_layout_" + d.id + "(unsigned long *s) {\n" + body + "}\n";
}

// The number of entries layout_text writes for D.
std::size_t layout_slots(const Declaration& d) {
  std::size_t n = d.params.size() + 1;
  for (const Declaration::Callback& cb : d.callbacks) n += 1 + cb.params.size();
  return n;
}

// The argument expressions of D's fixed parameters, reading a[i] as each kind says (struct: a pointer to the bytes).
std::vector<std::string> fixed_args(const Declaration& d) {
  std::vector<std::string> out;
  for (std::size_t i = 0; i < d.params.size(); ++i) {
    char k = d.param_kinds[i];
    std::string slot = "a[" + std::to_string(i) + "]";
    std::string type = abstract_type(d.params[i]);
    if (k == 'c') {
      std::string ctx = callback_context(d, i);
      out.push_back(ctx + " ? (" + type + ")" + callback_trampoline(d, i) + " : (" + type + ")" + callback_raw(d, i));
    } else if (k == 's') {
      out.push_back("*(" + type + " *)" + slot);
    } else {
      std::string src = k == 'i' ? "*(long long *)" + slot
                      : k == 'u' ? "*(unsigned long long *)" + slot
                      : k == 'f' ? "*(double *)" + slot
                                 : "*(void **)" + slot;
      out.push_back("(" + type + ")" + src);
    }
  }
  return out;
}

std::string join(const std::vector<std::string>& parts) {
  std::string out;
  for (std::size_t i = 0; i < parts.size(); ++i) out += (i ? ", " : "") + parts[i];
  return out;
}

// The statement that stores CALL's value in r by D's return kind.
std::string store_result(const Declaration& d, const std::string& call) {
  switch (d.return_kind) {
    case 'i': return "*(long long *)r = (long long)" + call;
    case 'u': return "*(unsigned long long *)r = (unsigned long long)" + call;
    case 'f': return "*(double *)r = (double)" + call;
    case 'p': return "*(void **)r = (void *)" + call;
    case 's': return "*(" + abstract_type(d.return_type) + " *)r = " + call;
    default: return call;
  }
}

// The wrapper for D: void nfcffi_call_NAME(void **a, void *r).
std::string wrapper_text(const Declaration& d, bool cxx) {
  std::string prefix;
  for (std::size_t i = 0; i < d.param_kinds.size(); ++i) {
    if (d.param_kinds[i] == 'c') {
      // the argument is a pair {raw function pointer, host callback slot}
      std::string pair = "((void **)*(void **)a[" + std::to_string(i) + "])";
      prefix += callback_context(d, i) + " = " + pair + "[1]; " + callback_raw(d, i) + " = " + pair + "[0]; ";
    }
  }
  return linkage(cxx) + "void nfcffi_call_" + d.id + "(void **a, void *r) {\n  " + prefix +
         store_result(d, d.name + "(" + join(fixed_args(d)) + ")") + ";\n}\n";
}

// The wrapper of a variadic D for the extra arguments of kinds SEQ ("n" integer, "f" double, "p" pointer), read from
// a[fixed + k]: void nfcffi_vcall_NAME_SEQ(void **a, void *r).
std::string vcall_text(const Declaration& d, const std::string& seq, bool cxx) {
  std::vector<std::string> args = fixed_args(d);
  for (std::size_t k = 0; k < seq.size(); ++k) {
    std::string slot = "a[" + std::to_string(d.params.size() + k) + "]";
    args.push_back(seq[k] == 'n' ? "*(long long *)" + slot
                 : seq[k] == 'f' ? "*(double *)" + slot
                                 : "*(void **)" + slot);
  }
  return linkage(cxx) + "void nfcffi_vcall_" + d.id + "_" + seq + "(void **a, void *r) {\n  " +
         store_result(d, d.name + "(" + join(args) + ")") + ";\n}\n";
}

// A variadic function with only scalar fixed arguments and result: callable with extra arguments.
bool variadic_ok(const Declaration& d) {
  if (!d.variadic || d.overloaded) return false;
  if (d.return_kind == 'x' || d.return_kind == 's' || std::strchr("iufpv", d.return_kind) == nullptr) return false;
  if (d.param_kinds.size() != d.params.size()) return false;
  for (char k : d.param_kinds) {
    if (k == 'v' || k == 's' || k == 'x' || std::strchr("iufp", k) == nullptr) return false;
  }
  return true;
}

// The promoted kind of a variadic argument.
char vararg_kind(const Value& v, std::size_t i) {
  switch (v.kind()) {
    case Value::Kind::Signed:
    case Value::Kind::Unsigned: return 'n';
    case Value::Kind::Float: return 'f';
    case Value::Kind::Pointer: return 'p';
    default:
      throw Error("nfcffi: variadic argument " + std::to_string(i) + " must be an integer, a float or a pointer");
  }
}


const Declaration* find_declaration(const std::vector<Declaration>& decls, const std::string& name) {
  for (const Declaration& d : decls) {
    if (d.name == name) return &d;
  }
  return nullptr;
}

// A callback parameter of D, as C code: its context variable and a trampoline with the declared signature. The trampoline
// stores its arguments canonically (long long, unsigned long long, double, void *), calls the host dispatcher with its
// context, and returns the result converted to the declared type.
std::string callback_text(const Declaration& d) {
  std::string out;
  for (const Declaration::Callback& cb : d.callbacks) {
    const std::size_t n = cb.params.size();
    std::string params, canon, argv;
    for (std::size_t j = 0; j < n; ++j) {
      std::string pn = "p" + std::to_string(j), cn = "c" + std::to_string(j);
      std::string decl;
      for (char c : cb.params[j]) {
        if (c == '@') decl += pn;
        else decl += c;
      }
      char k = cb.param_kinds[j];
      std::string ctype = k == 'i' ? "long long" : k == 'u' ? "unsigned long long" : k == 'f' ? "double" : "void *";
      // a struct parameter is passed as the address of its bytes
      std::string init = k == 's' ? "&" + pn : "(" + ctype + ")" + pn;
      params += (j ? ", " : "") + decl;
      canon += "  " + ctype + " " + cn + " = " + init + ";\n";
      argv += (j ? ", &" : "&") + cn;
    }
    if (n == 0) params = "void";
    std::string body = "  void *a[" + std::to_string(n ? n : 1) + "] = {" + (n ? argv : std::string("0")) + "};\n";
    std::string ret = cb.return_type;
    std::string rtype = cb.return_kind == 'i' ? "long long" : cb.return_kind == 'u' ? "unsigned long long"
                      : cb.return_kind == 'f' ? "double" : "void *";
    if (cb.return_kind == 'v') {
      body += "  nfcffi_host_dispatch(" + callback_context(d, cb.index) + ", a, 0);\n";
    } else if (cb.return_kind == 's') {
      // a struct result: the host writes its bytes into a variable of the declared type
      body += "  " + ret + " rs;\n  nfcffi_host_dispatch(" + callback_context(d, cb.index) + ", a, &rs);\n  return rs;\n";
    } else {
      body += "  " + rtype + " rv = 0;\n  nfcffi_host_dispatch(" + callback_context(d, cb.index) + ", a, &rv);\n" +
              "  return (" + ret + ")rv;\n";
    }
    out += "void *" + callback_context(d, cb.index) + ";\nvoid *" + callback_raw(d, cb.index) + ";\n" + ret + " " +
           callback_trampoline(d, cb.index) + "(" + params +
           ") {\n" + canon + body + "}\n";
  }
  return out;
}

// A host callable's state while a call uses it: the function, the parameter's signature and an exception it threw (it
// cannot cross the C frames, so it is rethrown after the call).
struct CallbackSlot {
  const CallableFn* fn = nullptr;
  const Declaration::Callback* sig = nullptr;
  std::exception_ptr error;
  void* words[2] = {nullptr, nullptr};  // {raw function pointer, this slot}: the argument the wrapper reads
};

// The host side of every trampoline: the arguments are canonical (see callback_text); the result is stored the same way.
void dispatch_callback(void* ctx, void** a, void* r) {
  CallbackSlot* s = static_cast<CallbackSlot*>(ctx);
  try {
    std::vector<Value> args;
    for (std::size_t i = 0; i < s->sig->param_kinds.size(); ++i) {
      switch (s->sig->param_kinds[i]) {
        case 'i': args.push_back(Value::of_signed(*(long long*)a[i])); break;
        case 'u': args.push_back(Value::of_unsigned(*(unsigned long long*)a[i])); break;
        case 'f': args.push_back(Value::of_float(*(double*)a[i])); break;
        case 's': args.push_back(Value::of_bytes(*(void**)a[i], s->sig->sizes.at(i + 1))); break;
        default: args.push_back(Value::of_pointer(*(void**)a[i])); break;
      }
    }
    Value v = (*s->fn)(args);
    if (r == nullptr) return;
    if (s->sig->return_kind == 's') {
      const std::vector<unsigned char>& bytes = v.as_bytes();
      if (bytes.size() != s->sig->sizes.at(0)) throw Error("nfcffi: a callback's struct result has the wrong size");
      std::memcpy(r, bytes.data(), bytes.size());
      return;
    }
    switch (s->sig->return_kind) {
      case 'i':
        *(long long*)r = v.kind() == Value::Kind::Unsigned ? (long long)v.as_unsigned() : v.as_signed();
        break;
      case 'u':
        *(unsigned long long*)r = v.kind() == Value::Kind::Signed ? (unsigned long long)v.as_signed() : v.as_unsigned();
        break;
      case 'f':
        *(double*)r = v.kind() == Value::Kind::Float ? v.as_float() : (double)v.as_signed();
        break;
      default:
        *(void**)r = v.kind() == Value::Kind::Pointer ? const_cast<void*>(v.as_pointer()) : nullptr;
        break;
    }
  } catch (...) {
    if (!s->error) s->error = std::current_exception();
    if (r != nullptr) std::memset(r, 0, s->sig->return_kind == 's' ? s->sig->sizes.at(0) : 8);
  }
}

std::string absolute_path(const std::string& p) {
  char buf[PATH_MAX];
  if (::realpath(p.c_str(), buf) == nullptr) throw Error("nfcffi: cannot find header '" + p + "'");
  return buf;
}

}  // namespace

Library Ffi::load(const std::string& header, const std::string& source, const std::vector<std::string>& only,
                  Dialect dialect) const {
  Library lib;
  const std::string path = absolute_path(header);
  const bool cxx = dialect == Dialect::Cxx;
  lib.ffi_ = *this;
  lib.header_ = path;
  lib.source_ = source;
  lib.cxx_ = cxx;
  lib.decls_ = declarations(path, dialect);

  // One translation unit: the header, the source, then a wrapper and a layout function for each passable function.
  // Variadic functions get their wrappers when they are called (Library::vwrapper).
  std::string text = "#include \"" + path + "\"\n" + source + "\n" +
                     "void (*nfcffi_host_dispatch)(void *, void **, void *);\n";
  std::vector<Declaration*> wrapped;
  for (Declaration& d : lib.decls_) {
    if (!only.empty() && std::find(only.begin(), only.end(), d.name) == only.end()) continue;
    if (variadic_ok(d)) {
      lib.variadic_.insert(d.name);
      continue;
    }
    if (!passable(d)) continue;
    text += callback_text(d) + wrapper_text(d, cxx) + layout_text(d, cxx);
    wrapped.push_back(&d);
  }

  lib.module_ = compile(text, cxx);
  *lib.module_.variable<void (*)(void*, void**, void*)>("nfcffi_host_dispatch") = &dispatch_callback;
  for (Declaration* d : wrapped) {
    lib.wrappers_.emplace(d->id, lib.module_.function<void(void**, void*)>("nfcffi_call_" + d->id));
    auto layout = lib.module_.function<void(unsigned long*)>("nfcffi_layout_" + d->id);
    std::vector<unsigned long> sz(layout_slots(*d), 0);
    layout(sz.data());
    lib.layouts_.emplace(d->id, layout);
    lib.sizes_[d->id] = std::vector<std::size_t>(sz.begin(), sz.begin() + d->params.size() + 1);
    // the callbacks' sizes follow the parameters' (see layout_text)
    std::size_t next = d->params.size() + 1;
    for (Declaration::Callback& cb : d->callbacks) {
      cb.sizes.assign(sz.begin() + next, sz.begin() + next + 1 + cb.params.size());
      next += 1 + cb.params.size();
    }
  }
  return lib;
}

// The wrapper of variadic D for the extra kinds SEQ, compiled with the header and source on first use.
const Function<void(void**, void*)>& Library::vwrapper(const Declaration& d, const std::string& seq) const {
  std::string key = d.name + "#" + seq;
  auto found = vwrappers_.find(key);
  if (found != vwrappers_.end()) return found->second;
  std::string text = "#include \"" + header_ + "\"\n" + source_ + "\n" + vcall_text(d, seq, cxx_);
  Module m = ffi_.compile(text, cxx_);
  Function<void(void**, void*)> fn = m.function<void(void**, void*)>("nfcffi_vcall_" + d.name + "_" + seq);
  vmodules_.emplace(key, std::move(m));
  return vwrappers_.emplace(key, fn).first->second;
}

bool Library::callable(const std::string& name) const {
  if (variadic_.count(name) != 0) return true;
  for (const Declaration& d : decls_) {
    if (d.name == name && wrappers_.count(d.id) != 0) return true;
  }
  return false;
}

namespace {

// How well a declaration takes ARGS: -1 when it does not, else the number of arguments that match a parameter exactly.
int overload_score(const Declaration& d, const std::vector<Value>& args) {
  if (args.size() != d.params.size()) return -1;
  int exact = 0;
  for (std::size_t i = 0; i < args.size(); ++i) {
    const char k = d.param_kinds[i];
    const Value::Kind vk = args[i].kind();
    const bool same = (k == 'i' && vk == Value::Kind::Signed) || (k == 'u' && vk == Value::Kind::Unsigned) ||
                      (k == 'f' && vk == Value::Kind::Float) || (k == 'p' && vk == Value::Kind::Pointer) ||
                      (k == 's' && vk == Value::Kind::Bytes) || (k == 'c' && vk == Value::Kind::Callable);
    // the conversions call() makes
    const bool converts = (k == 'i' && vk == Value::Kind::Unsigned) || (k == 'u' && vk == Value::Kind::Signed) ||
                          (k == 'f' && (vk == Value::Kind::Signed || vk == Value::Kind::Unsigned)) ||
                          (k == 'p' && vk == Value::Kind::Signed) ||
                          (k == 'c' && (vk == Value::Kind::Pointer || vk == Value::Kind::Signed));
    if (!same && !converts) return -1;
    exact += same ? 1 : 0;
  }
  return exact;
}

}  // namespace

// The declaration NAME with ARGS: the callable overload that takes them best. Null when NAME has no callable declaration.
const Declaration* Library::select(const std::string& name, const std::vector<Value>& args) const {
  const Declaration* best = nullptr;
  int best_score = -1;
  bool any = false;
  for (const Declaration& d : decls_) {
    if (d.name != name || wrappers_.count(d.id) == 0) continue;
    any = true;
    const int score = overload_score(d, args);
    if (score > best_score) {
      best = &d;
      best_score = score;
    }
  }
  if (!any) return nullptr;
  if (best == nullptr) throw Error("nfcffi: no overload of " + name + " takes these arguments");
  return best;
}

std::vector<std::size_t> Library::member_offsets(const std::string& type, const std::vector<std::string>& members) const {
  std::string body = "  o[0] = sizeof(" + type + ");\n";
  for (std::size_t i = 0; i < members.size(); ++i) {
    const std::string& m = members[i];
    if (m.empty() || !std::all_of(m.begin(), m.end(), [](char c) { return std::isalnum((unsigned char)c) || c == '_'; })) {
      throw Error("nfcffi: member_offsets: '" + m + "' is not a member name");
    }
    body += "  o[" + std::to_string(i + 1) + "] = offsetof(" + type + ", " + m + ");\n";
  }
  // compiled with the header and source, like a variadic wrapper; the module is closed once its values are read
  const std::string text = "#include <stddef.h>\n#include \"" + header_ + "\"\n" + source_ + "\n" +
                           linkage(cxx_) + "void nfcffi_offsets(unsigned long *o) {\n" + body + "}\n";
  Module m = ffi_.compile(text, cxx_);
  std::vector<unsigned long> o(members.size() + 1, 0);
  m.function<void(unsigned long*)>("nfcffi_offsets")(o.data());
  return std::vector<std::size_t>(o.begin(), o.end());
}

Value Library::call(const std::string& name, const std::vector<Value>& args) const {
  const bool variadic = variadic_.count(name) != 0;
  const Declaration* d = variadic ? find_declaration(decls_, name) : select(name, args);
  const bool fixed = !variadic && d != nullptr;
  if (d == nullptr || !(fixed || variadic)) {
    throw Error("nfcffi: '" + name + "' is not callable: it is not a function of the header, or it has a struct, "
                "overloaded or long double part");
  }
  const std::size_t nfixed = d->params.size();
  if (fixed ? args.size() != nfixed : args.size() < nfixed) {
    throw Error("nfcffi: " + name + " takes " + std::string(variadic ? "at least " : "") + std::to_string(nfixed) +
                " arguments, got " + std::to_string(args.size()));
  }

  // The kinds of all arguments: the declared ones, then the promoted kinds of the extra ones.
  std::string seq;
  for (std::size_t i = nfixed; i < args.size(); ++i) seq += vararg_kind(args[i], i);
  const std::vector<std::size_t>* sz = fixed ? &sizes_.at(d->id) : nullptr;

  std::size_t n = args.size();
  std::vector<long long> sv(n);
  std::vector<unsigned long long> uv(n);
  std::vector<double> fv(n);
  std::vector<void*> pv(n);
  std::vector<void*> slots(n);
  std::vector<CallbackSlot> cbslots(n);
  for (std::size_t i = 0; i < n; ++i) {
    const Value& v = args[i];
    const char k = i < nfixed ? d->param_kinds[i] : seq[i - nfixed];
    const std::string where = "nfcffi: argument " + std::to_string(i) + " of " + name;
    switch (k) {
      case 'c':
        // a host callable (through its trampoline), a C function pointer (as is), or nil
        if (v.kind() == Value::Kind::Callable) {
          cbslots[i].fn = &v.as_callable();
          cbslots[i].sig = callback_at(*d, i);
          cbslots[i].words[1] = &cbslots[i];
        } else if (v.kind() == Value::Kind::Pointer) {
          cbslots[i].words[0] = const_cast<void*>(v.as_pointer());
        } else if (v.kind() == Value::Kind::Signed && v.as_signed() == 0) {
          // nil: both words stay null
        } else {
          throw Error(where + " must be a host callable, a function pointer or nil");
        }
        pv[i] = cbslots[i].words;
        slots[i] = &pv[i];
        break;
      case 's':
        if (v.kind() != Value::Kind::Bytes) throw Error(where + " must be a struct or union (Value::of_bytes)");
        if (v.as_bytes().size() != (*sz)[i + 1]) {
          throw Error(where + " must be " + std::to_string((*sz)[i + 1]) + " bytes, got " +
                      std::to_string(v.as_bytes().size()));
        }
        slots[i] = const_cast<unsigned char*>(v.as_bytes().data());
        break;
      case 'i':
      case 'n':
        if (v.kind() == Value::Kind::Signed) sv[i] = v.as_signed();
        else if (v.kind() == Value::Kind::Unsigned) sv[i] = (long long)v.as_unsigned();
        else throw Error(where + " must be an integer");
        slots[i] = &sv[i];
        break;
      case 'u':
        if (v.kind() == Value::Kind::Unsigned) uv[i] = v.as_unsigned();
        else if (v.kind() == Value::Kind::Signed) uv[i] = (unsigned long long)v.as_signed();
        else throw Error(where + " must be an integer");
        slots[i] = &uv[i];
        break;
      case 'f':
        if (v.kind() == Value::Kind::Float) fv[i] = v.as_float();
        else if (v.kind() == Value::Kind::Signed) fv[i] = (double)v.as_signed();
        else if (v.kind() == Value::Kind::Unsigned) fv[i] = (double)v.as_unsigned();
        else throw Error(where + " must be a number");
        slots[i] = &fv[i];
        break;
      default:  // 'p'
        if (v.kind() == Value::Kind::Pointer) pv[i] = const_cast<void*>(v.as_pointer());
        else if (v.kind() == Value::Kind::Signed && v.as_signed() == 0) pv[i] = nullptr;
        else throw Error(where + " must be a pointer");
        slots[i] = &pv[i];
        break;
    }
  }

  long long rs = 0;
  unsigned long long ru = 0;
  double rf = 0;
  void* rp = nullptr;
  std::vector<unsigned char> rb(sz ? (*sz)[0] : 0);
  void* out = nullptr;
  switch (d->return_kind) {
    case 'i': out = &rs; break;
    case 'u': out = &ru; break;
    case 'f': out = &rf; break;
    case 'p': out = &rp; break;
    case 's': out = rb.data(); break;
    default: break;
  }
  const Function<void(void**, void*)>& w = fixed ? wrappers_.at(d->id) : vwrapper(*d, seq);
  w(slots.data(), out);
  for (const CallbackSlot& cb : cbslots) {
    if (cb.error) std::rethrow_exception(cb.error);
  }

  switch (d->return_kind) {
    case 'i': return Value::of_signed(rs);
    case 'u': return Value::of_unsigned(ru);
    case 'f': return Value::of_float(rf);
    case 'p': return Value::of_pointer(rp);
    case 's': return Value::of_bytes(rb.data(), rb.size());
    default: return Value();
  }
}

}  // namespace nfcffi
