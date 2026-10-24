// nfcffi implementation. See nfcffi.hpp and docs/notes/ffi.md. The driver lookup, hashing, cache directory, child process and
// the file helpers are nfceval's (lib/eval/nfceval_build.hpp), so both libraries compile the same way.
#include "nfcffi.hpp"

#include <dlfcn.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <map>
#include <cstdlib>
#include <cstring>

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
