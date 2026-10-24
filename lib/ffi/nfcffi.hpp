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
#include <cstddef>
#include <cstring>
#include <map>
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

// A function declared in a header, as the front end reads it (docs/notes/ffi.md, "Declarations").
struct Declaration {
  std::string name;
  std::string return_type;               // a C type, e.g. "const char *" or "size_t"
  std::vector<std::string> params;       // C types; "@" marks where the name goes: "int (*@)(const void *, const void *)"
  bool variadic = false;                 // a trailing "..."
  bool overloaded = false;               // C++ overloads share the name (C has one function per name)
  char return_kind = 'x';                // how the return value crosses a call: i u f p v, or x (see Library)
  std::string param_kinds;               // one letter per parameter, same alphabet

  // The declaration of parameter I with NAME ("int (*cmp)(const void *, const void *)"); an empty NAME gives the abstract type.
  std::string param_decl(std::size_t i, const std::string& name) const;
};

// A value passed to or returned from Library::call: a signed or unsigned integer, a float or double, a pointer, void, or
// a struct or union passed by value, as its bytes (the C layout of the type, see Library::call).
class Value {
 public:
  enum class Kind { Void, Signed, Unsigned, Float, Pointer, Bytes };

  Value() = default;
  static Value of_signed(long long v);
  static Value of_unsigned(unsigned long long v);
  static Value of_float(double v);
  static Value of_pointer(const void* p);
  static Value of_bytes(const void* p, std::size_t n);

  Kind kind() const { return kind_; }
  // Each accessor throws Error when the value has another kind.
  long long as_signed() const;
  unsigned long long as_unsigned() const;
  double as_float() const;
  const void* as_pointer() const;
  const std::vector<unsigned char>& as_bytes() const;

 private:
  Kind kind_ = Kind::Void;
  long long s_ = 0;
  unsigned long long u_ = 0;
  double f_ = 0;
  const void* p_ = nullptr;
  std::vector<unsigned char> b_;
};

// A set of header declarations compiled into one shared object, with a wrapper per function that can be called by name
// (Library::callable). A wrapper converts its arguments from the kinds of the declaration: integers, floats, pointers,
// and structs or unions by value. Variadic functions, overload sets and 128-bit or long double values are not callable
// (the declaration is still listed). Move-only.
class Library {
 public:
  const std::vector<Declaration>& declarations() const { return decls_; }
  bool callable(const std::string& name) const { return wrappers_.count(name) != 0; }

  // Calls NAME with ARGS, converted to the declared parameter kinds: signed and unsigned integers convert to each other,
  // integers convert to float, and a pointer parameter takes a pointer or the integer 0. A struct or union parameter takes
  // Value::of_bytes of the object's bytes, of the size the C compiler gives the type (the same layout as a C++ struct
  // with the same members); a struct result comes back the same way. Throws Error for an uncallable name, a wrong argument
  // count or kind, or a wrong size.
  Value call(const std::string& name, const std::vector<Value>& args) const;

 private:
  friend class Ffi;
  std::vector<Declaration> decls_;
  std::map<std::string, Function<void(void**, void*)>> wrappers_;
  std::map<std::string, Function<void(unsigned long*)>> layouts_;
  std::map<std::string, std::vector<std::size_t>> sizes_;  // [0] the result's size, [i + 1] parameter i's (0 unless a struct)
  Module module_;
};

// The compiler and its options. Compiling the same source with the same options reuses the shared object in the cache.
class Ffi {
 public:
  // DRIVER: the nfcxx driver; empty means $NFCXX, then <repo>/nfcxx, then `nfcxx` on PATH.
  explicit Ffi(std::string driver = {});

  Ffi& add_flag(std::string flag);           // -I..., -D..., --backend=...
  Ffi& set_cache_dir(std::string dir);       // default $NFCFFI_CACHE, else $TMPDIR/nfcffi-cache-<uid>
  Ffi& set_compile_timeout(unsigned seconds);  // 0 disables; default 300
  Ffi& set_decl_tool(std::string path);        // scripts/libclang-cursors; default <repo>/scripts/libclang-cursors

  // Compiles SOURCE (C) into a shared object and loads it. Throws CompileError when the source does not compile.
  Module compile(const std::string& source) const;

  // Compiles HEADER (with SOURCE after it, when given) and a wrapper for each callable function of HEADER, or only for
  // the functions in ONLY when it is not empty. The header's path is included as is, so give an absolute path.
  Library load(const std::string& header, const std::string& source = {}, const std::vector<std::string>& only = {}) const;

  // The functions declared in FILE and in the headers it includes (with their signatures), in the order the front end
  // lists them. CXX reads the file as C++ (overloads come out flagged); the default reads it as C. Reads the front end of the
  // libclang shim: build with scripts/setup-libclang-edg.sh. Throws Error when the tool cannot be run, CompileError when the
  // file does not parse.
  enum class Dialect { C, Cxx };
  std::vector<Declaration> declarations(const std::string& file, Dialect dialect = Dialect::C) const;

  const std::string& driver() const { return driver_; }
  const std::string& cache_dir() const { return cache_; }

 private:
  std::string driver_;
  std::string cache_;
  std::vector<std::string> flags_;
  std::string decl_tool_;
  unsigned timeout_ = 300;
};

}  // namespace nfcffi
