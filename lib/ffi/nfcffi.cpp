// nfcffi implementation. See nfcffi.hpp and docs/notes/ffi.md. The driver lookup, hashing, cache directory, child process and
// the file helpers are nfceval's (lib/eval/nfceval_build.hpp), so both libraries compile the same way.
#include "nfcffi.hpp"

#include <dlfcn.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

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

Module Ffi::compile(const std::string& source) const {
  std::string err = build::ensure_cache_dir(cache_);
  if (!err.empty()) throw Error("nfcffi: " + err);

  // The key covers everything that changes the object: the source, the driver, the flags and the back end.
  std::string key_text = source + '\0' + driver_ + '\0';
  for (const std::string& f : flags_) key_text += f + '\0';
  if (const char* be = std::getenv("NFCXX_BACKEND")) key_text += be;
  std::string base = cache_ + "/nfcffi-" + build::hash_hex(key_text);
  std::string so = base + ".so";

  if (!build::file_exists(so)) {
    std::string c_file = base + ".c";
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

namespace {

// A function can be called by name when its declaration has no variadic part, is not overloaded, and passes only
// integers, floats and pointers (void as the result).
bool passable(const Declaration& d) {
  if (d.variadic || d.overloaded) return false;
  if (d.return_kind == 'x' || std::strchr("iufpv", d.return_kind) == nullptr) return false;
  if (d.param_kinds.size() != d.params.size()) return false;
  for (char k : d.param_kinds) {
    if (k == 'v' || k == 'x' || std::strchr("iufp", k) == nullptr) return false;
  }
  return true;
}

// The wrapper for D: void nfcffi_call_NAME(void **a, void *r). Each argument is read from a[i] as its kind says
// (long long, unsigned long long, double or void *); the result is stored in r the same way.
std::string wrapper_text(const Declaration& d) {
  std::string args;
  for (std::size_t i = 0; i < d.params.size(); ++i) {
    char k = d.param_kinds[i];
    std::string slot = "a[" + std::to_string(i) + "]";
    std::string src = k == 'i' ? "*(long long *)" + slot
                    : k == 'u' ? "*(unsigned long long *)" + slot
                    : k == 'f' ? "*(double *)" + slot
                               : "*(void **)" + slot;
    args += (i ? ", (" : "(") + abstract_type(d.params[i]) + ")" + src;
  }
  std::string call = d.name + "(" + args + ")";
  std::string body;
  switch (d.return_kind) {
    case 'i': body = "*(long long *)r = (long long)" + call; break;
    case 'u': body = "*(unsigned long long *)r = (unsigned long long)" + call; break;
    case 'f': body = "*(double *)r = (double)" + call; break;
    case 'p': body = "*(void **)r = (void *)" + call; break;
    default: body = call; break;
  }
  return "void nfcffi_call_" + d.name + "(void **a, void *r) {\n  " + body + ";\n}\n";
}

std::string absolute_path(const std::string& p) {
  char buf[PATH_MAX];
  if (::realpath(p.c_str(), buf) == nullptr) throw Error("nfcffi: cannot find header '" + p + "'");
  return buf;
}

}  // namespace

Library Ffi::load(const std::string& header, const std::string& source, const std::vector<std::string>& only) const {
  Library lib;
  const std::string path = absolute_path(header);
  lib.decls_ = declarations(path);

  // One translation unit: the header, the source, then a wrapper for each passable function.
  std::string text = "#include \"" + path + "\"\n" + source + "\n";
  std::vector<std::string> wrapped;
  for (const Declaration& d : lib.decls_) {
    if (!only.empty() && std::find(only.begin(), only.end(), d.name) == only.end()) continue;
    if (!passable(d)) continue;
    text += wrapper_text(d);
    wrapped.push_back(d.name);
  }

  lib.module_ = compile(text);
  for (const std::string& name : wrapped) {
    lib.wrappers_.emplace(name, lib.module_.function<void(void**, void*)>("nfcffi_call_" + name));
  }
  return lib;
}

Value Library::call(const std::string& name, const std::vector<Value>& args) const {
  auto w = wrappers_.find(name);
  const Declaration* d = nullptr;
  for (const Declaration& x : decls_) {
    if (x.name == name) d = &x;
  }
  if (w == wrappers_.end() || d == nullptr) {
    throw Error("nfcffi: '" + name + "' is not callable: it is not a function of the header, or it has a struct, variadic, "
                "overloaded or long double part");
  }
  if (args.size() != d->params.size()) {
    throw Error("nfcffi: " + name + " takes " + std::to_string(d->params.size()) + " arguments, got " +
                std::to_string(args.size()));
  }

  std::size_t n = args.size();
  std::vector<long long> sv(n);
  std::vector<unsigned long long> uv(n);
  std::vector<double> fv(n);
  std::vector<void*> pv(n);
  std::vector<void*> slots(n);
  for (std::size_t i = 0; i < n; ++i) {
    const Value& v = args[i];
    const std::string where = "nfcffi: argument " + std::to_string(i) + " of " + name;
    switch (d->param_kinds[i]) {
      case 'i':
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
  void* out = nullptr;
  switch (d->return_kind) {
    case 'i': out = &rs; break;
    case 'u': out = &ru; break;
    case 'f': out = &rf; break;
    case 'p': out = &rp; break;
    default: break;
  }
  w->second(slots.data(), out);

  switch (d->return_kind) {
    case 'i': return Value::of_signed(rs);
    case 'u': return Value::of_unsigned(ru);
    case 'f': return Value::of_float(rf);
    case 'p': return Value::of_pointer(rp);
    default: return Value();
  }
}

}  // namespace nfcffi
