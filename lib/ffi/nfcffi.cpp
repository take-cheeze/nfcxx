// nfcffi implementation. See nfcffi.hpp and docs/notes/ffi.md. The driver lookup, hashing, cache directory, child process and
// the file helpers are nfceval's (lib/eval/nfceval_build.hpp), so both libraries compile the same way.
#include "nfcffi.hpp"

#include <dlfcn.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
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
      cache_(build::default_cache_dir("NFCFFI_CACHE", "nfcffi-cache")) {}

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
