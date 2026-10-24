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
bool passable(const Declaration& d) {
  if (d.variadic || d.overloaded) return false;
  if (d.return_kind == 'x' || std::strchr("iufpvs", d.return_kind) == nullptr) return false;
  if (d.param_kinds.size() != d.params.size()) return false;
  for (char k : d.param_kinds) {
    if (k == 'v' || k == 'x' || std::strchr("iufps", k) == nullptr) return false;
  }
  return true;
}

// The layout function for D: void nfcffi_layout_NAME(unsigned long *s) stores the size of the result type at s[0] and of
// parameter i at s[i + 1]; 0 for the types that are not structs or unions.
std::string layout_text(const Declaration& d) {
  std::string body = d.return_kind == 's' ? "  s[0] = sizeof(" + abstract_type(d.return_type) + ");\n" : "  s[0] = 0;\n";
  for (std::size_t i = 0; i < d.params.size(); ++i) {
    std::string n = std::to_string(i + 1);
    body += d.param_kinds[i] == 's' ? "  s[" + n + "] = sizeof(" + abstract_type(d.params[i]) + ");\n"
                                    : "  s[" + n + "] = 0;\n";
  }
  return "void nfcffi_layout_" + d.name + "(unsigned long *s) {\n" + body + "}\n";
}

// The argument expressions of D's fixed parameters, reading a[i] as each kind says (struct: a pointer to the bytes).
std::vector<std::string> fixed_args(const Declaration& d) {
  std::vector<std::string> out;
  for (std::size_t i = 0; i < d.params.size(); ++i) {
    char k = d.param_kinds[i];
    std::string slot = "a[" + std::to_string(i) + "]";
    std::string type = abstract_type(d.params[i]);
    if (k == 's') {
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
std::string wrapper_text(const Declaration& d) {
  return "void nfcffi_call_" + d.name + "(void **a, void *r) {\n  " +
         store_result(d, d.name + "(" + join(fixed_args(d)) + ")") + ";\n}\n";
}

// The wrapper of a variadic D for the extra arguments of kinds SEQ ("n" integer, "f" double, "p" pointer), read from
// a[fixed + k]: void nfcffi_vcall_NAME_SEQ(void **a, void *r).
std::string vcall_text(const Declaration& d, const std::string& seq) {
  std::vector<std::string> args = fixed_args(d);
  for (std::size_t k = 0; k < seq.size(); ++k) {
    std::string slot = "a[" + std::to_string(d.params.size() + k) + "]";
    args.push_back(seq[k] == 'n' ? "*(long long *)" + slot
                 : seq[k] == 'f' ? "*(double *)" + slot
                                 : "*(void **)" + slot);
  }
  return "void nfcffi_vcall_" + d.name + "_" + seq + "(void **a, void *r) {\n  " +
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

std::string absolute_path(const std::string& p) {
  char buf[PATH_MAX];
  if (::realpath(p.c_str(), buf) == nullptr) throw Error("nfcffi: cannot find header '" + p + "'");
  return buf;
}

}  // namespace

Library Ffi::load(const std::string& header, const std::string& source, const std::vector<std::string>& only) const {
  Library lib;
  const std::string path = absolute_path(header);
  lib.ffi_ = *this;
  lib.header_ = path;
  lib.source_ = source;
  lib.decls_ = declarations(path);

  // One translation unit: the header, the source, then a wrapper and a layout function for each passable function.
  // Variadic functions get their wrappers when they are called (Library::vwrapper).
  std::string text = "#include \"" + path + "\"\n" + source + "\n";
  std::vector<std::string> wrapped;
  for (const Declaration& d : lib.decls_) {
    if (!only.empty() && std::find(only.begin(), only.end(), d.name) == only.end()) continue;
    if (variadic_ok(d)) {
      lib.variadic_.insert(d.name);
      continue;
    }
    if (!passable(d)) continue;
    text += wrapper_text(d) + layout_text(d);
    wrapped.push_back(d.name);
  }

  lib.module_ = compile(text);
  for (const std::string& name : wrapped) {
    lib.wrappers_.emplace(name, lib.module_.function<void(void**, void*)>("nfcffi_call_" + name));
    auto layout = lib.module_.function<void(unsigned long*)>("nfcffi_layout_" + name);
    std::vector<unsigned long> sz(find_declaration(lib.decls_, name)->params.size() + 1, 0);
    layout(sz.data());
    lib.layouts_.emplace(name, layout);
    lib.sizes_[name] = std::vector<std::size_t>(sz.begin(), sz.end());
  }
  return lib;
}

// The wrapper of variadic D for the extra kinds SEQ, compiled with the header and source on first use.
const Function<void(void**, void*)>& Library::vwrapper(const Declaration& d, const std::string& seq) const {
  std::string key = d.name + "#" + seq;
  auto found = vwrappers_.find(key);
  if (found != vwrappers_.end()) return found->second;
  std::string text = "#include \"" + header_ + "\"\n" + source_ + "\n" + vcall_text(d, seq);
  Module m = ffi_.compile(text);
  Function<void(void**, void*)> fn = m.function<void(void**, void*)>("nfcffi_vcall_" + d.name + "_" + seq);
  vmodules_.emplace(key, std::move(m));
  return vwrappers_.emplace(key, fn).first->second;
}

Value Library::call(const std::string& name, const std::vector<Value>& args) const {
  const Declaration* d = find_declaration(decls_, name);
  const bool fixed = wrappers_.count(name) != 0;
  const bool variadic = variadic_.count(name) != 0;
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
  const std::vector<std::size_t>* sz = fixed ? &sizes_.at(name) : nullptr;

  std::size_t n = args.size();
  std::vector<long long> sv(n);
  std::vector<unsigned long long> uv(n);
  std::vector<double> fv(n);
  std::vector<void*> pv(n);
  std::vector<void*> slots(n);
  for (std::size_t i = 0; i < n; ++i) {
    const Value& v = args[i];
    const char k = i < nfixed ? d->param_kinds[i] : seq[i - nfixed];
    const std::string where = "nfcffi: argument " + std::to_string(i) + " of " + name;
    switch (k) {
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
  const Function<void(void**, void*)>& w = fixed ? wrappers_.at(name) : vwrapper(*d, seq);
  w(slots.data(), out);

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
