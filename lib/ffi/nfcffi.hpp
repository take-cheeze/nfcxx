// nfcffi: compile C source at run time and call its functions through typed C++ function types. See docs/notes/ffi.md.
//
//   nfcffi::Ffi ffi;                                        // finds nfcxx, a cache directory
//   nfcffi::Module m = ffi.compile("int add(int a, int b) { return a + b; }");
//   auto add = m.function<int(int, int)>("add");           // the signature is spelled here, in C++
//   int r = add(4, 5);                                      // 9
//   auto strlen_ = nfcffi::process_function<size_t(const char*)>("strlen");   // from the C library
//
// The shared object is built with `nfcxx -shared` (C input) and cached by a hash of its source and options, as nfceval does.
#pragma once
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace nfcffi {

struct Error : std::runtime_error {
  using std::runtime_error::runtime_error;
};

// The C source did not compile (or the driver could not be run): what() has the driver's output.
struct CompileError : Error {
  using Error::Error;
};

// A C function pointer with the signature Sig = R(A...). Calls go straight to the address; the object must not outlive
// the Module it came from (or the process's C library, for process_function).
template <class Sig>
class Function;

template <class R, class... A>
class Function<R(A...)> {
 public:
  using pointer = R (*)(A...);

  explicit Function(pointer p) : p_(p) {}
  R operator()(A... args) const { return p_(args...); }
  pointer get() const { return p_; }

 private:
  pointer p_;
};

// The address of a function of the running program or of the C library (dlsym on RTLD_DEFAULT), typed as Sig.
// Throws Error when the name is not found.
void* process_symbol(const std::string& name);

template <class Sig>
Function<Sig> process_function(const std::string& name) {
  typename Function<Sig>::pointer p;
  void* s = process_symbol(name);
  std::memcpy(&p, &s, sizeof p);
  return Function<Sig>(p);
}

// The shared object compiled from one source text, dlclose'd on destruction. Move-only.
class Module {
 public:
  Module() = default;
  Module(Module&& other) noexcept : handle_(other.handle_) { other.handle_ = nullptr; }
  Module& operator=(Module&& other) noexcept;
  Module(const Module&) = delete;
  Module& operator=(const Module&) = delete;
  ~Module();

  bool valid() const { return handle_ != nullptr; }

  // NAME as a function of type Sig = R(A...). Throws Error when the module has no such symbol.
  template <class Sig>
  Function<Sig> function(const std::string& name) const {
    typename Function<Sig>::pointer p;
    void* s = symbol(name);
    std::memcpy(&p, &s, sizeof p);
    return Function<Sig>(p);
  }

 private:
  friend class Ffi;
  explicit Module(void* handle) : handle_(handle) {}
  void* symbol(const std::string& name) const;

  void* handle_ = nullptr;
};

// The compiler and its options. Compiling the same source with the same options reuses the shared object in the cache.
class Ffi {
 public:
  // DRIVER: the nfcxx driver; empty means $NFCXX, then <repo>/nfcxx, then `nfcxx` on PATH.
  explicit Ffi(std::string driver = {});

  Ffi& add_flag(std::string flag);           // -I..., -D..., --backend=...
  Ffi& set_cache_dir(std::string dir);       // default $NFCFFI_CACHE, else $TMPDIR/nfcffi-cache-<uid>
  Ffi& set_compile_timeout(unsigned seconds);  // 0 disables; default 300

  // Compiles SOURCE (C) into a shared object and loads it. Throws CompileError when the source does not compile.
  Module compile(const std::string& source) const;

  const std::string& driver() const { return driver_; }
  const std::string& cache_dir() const { return cache_; }

 private:
  std::string driver_;
  std::string cache_;
  std::vector<std::string> flags_;
  unsigned timeout_ = 300;
};

}  // namespace nfcffi
