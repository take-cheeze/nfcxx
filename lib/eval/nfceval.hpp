// nfceval: evaluate C++ snippets at run time, with the host's objects and functions bound by name.
//
//   nfceval::Engine eng;
//   int counter = 0;
//   eng.bind("counter", counter);                         // the snippet sees `int& counter`
//   eng.bind_fn("twice", +[](int x) { return 2 * x; });   // ... and `int twice(int)`
//   int r = eng.eval<int>("counter += 2; return twice(counter);");
//
// A snippet is compiled with the nfcxx driver into a shared object (cached by a hash of the generated
// source), dlopen'd and called. It is arbitrary native code running in the host process: there is no
// sandbox. See docs/notes/eval.md. Needs libc, libstdc++ and (glibc < 2.34) libdl only.
#pragma once
#include <cstddef>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace nfceval {

// Base class of every error the engine reports.
struct Error : std::runtime_error {
  using std::runtime_error::runtime_error;
};
// The snippet did not compile. what() is the compiler's stderr; line numbers refer to the snippet
// (the file name is "snippet": "snippet:2:5: error: ..." is line 2 of the text given to eval).
struct CompileError : Error {
  using Error::Error;
};
// The snippet threw. what() is the exception's what() (or "unknown exception").
struct RuntimeError : Error {
  using Error::Error;
};

namespace detail {

// Spells a type the way the compiler prints it in __PRETTY_FUNCTION__ ("T = ...").
template <class T>
std::string type_name_of() {
  std::string s = __PRETTY_FUNCTION__;
  std::size_t p = s.find("T = ");
  if (p == std::string::npos) return std::string();
  p += 4;
  int depth = 0;  // brackets inside the type (arrays) do not end it
  std::size_t e = p;
  for (; e < s.size(); ++e) {
    if (s[e] == '[') ++depth;
    else if (s[e] == ']' && depth-- == 0) break;
    else if (s[e] == ';' && depth == 0) break;
  }
  return s.substr(p, e - p);
}

// Function signatures, from function pointers, function types and (const) call operators.
template <class F, class = void>
struct sig;
template <class R, class... A>
struct sig<R(A...), void> {
  using ret = R;
  template <template <class...> class L>
  using apply = L<R, A...>;
};
template <class R, class... A>
struct sig<R (*)(A...), void> : sig<R(A...)> {};
template <class R, class... A>
struct sig<R (&)(A...), void> : sig<R(A...)> {};
template <class C, class R, class... A>
struct sig<R (C::*)(A...) const, void> : sig<R(A...)> {};
template <class C, class R, class... A>
struct sig<R (C::*)(A...), void> : sig<R(A...)> {};
template <class F>
struct sig<F, std::void_t<decltype(&F::operator())>> : sig<decltype(&F::operator())> {};

struct Slot {
  std::string name;
  std::string decl;                  // the C++ declaration the snippet sees (a reference or a function)
  std::vector<void*> words;          // table words this binding occupies
  std::unique_ptr<void, void (*)(void*)> keep{nullptr, nullptr};  // owns a callable's state
};

}  // namespace detail

class Engine {
 public:
  Engine();
  ~Engine();
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  // ---- configuration -------------------------------------------------------------------------
  // The nfcxx driver: set_driver(), else $NFCXX, else the repository's ./nfcxx (NFCEVAL_DEFAULT_DRIVER,
  // or found from this library's source path), else "nfcxx" on PATH.
  Engine& set_driver(std::string path);
  // Directory for generated sources and shared objects: set_cache_dir(), else $NFCEVAL_CACHE, else
  // $TMPDIR (or /tmp)/nfceval-cache-<uid>. Created on demand.
  Engine& set_cache_dir(std::string dir);
  // Extra driver arguments (for example "-I/path", "-DNAME=1", "--backend=gcc"). Part of the cache key.
  Engine& add_flag(std::string flag);
  // Kill the compiler after this many seconds (0: no limit, the default is 300).
  Engine& set_compile_timeout(unsigned seconds);
  // Text put at the top of every generated source, after the default includes
  // (<new> <exception> <string> <cstdio> <cstdlib> <cstring> <cmath>).
  Engine& prelude(const std::string& code);
  // prelude("#include \"x.hpp\"") for "x.hpp", prelude("#include <x>") for "<x>".
  Engine& include(const std::string& header);

  // ---- bindings ------------------------------------------------------------------------------
  // The snippet sees `T& name` (`const T& name` for a const object) referring to obj itself. T is
  // spelled from the compiler's type name; pass `type` to spell it yourself (needed for lambdas and
  // unnamed types). The object must outlive every eval that uses the binding. Binding a name again
  // replaces the earlier binding (a different type recompiles, the same type reuses the cache).
  template <class T>
  Engine& bind(const std::string& name, T& obj) {
    return bind_ref(name, detail::type_name_of<T>(), static_cast<void*>(const_cast<std::remove_cv_t<T>*>(&obj)));
  }
  template <class T>
  Engine& bind(const std::string& name, T& obj, const std::string& type) {
    return bind_ref(name, type, static_cast<void*>(const_cast<std::remove_cv_t<T>*>(&obj)));
  }

  // The snippet sees `R name(A...)`. f is a function, function pointer, lambda or other callable with
  // one non-template call operator (captures are fine; the engine keeps a copy). Argument and return
  // types are spelled from the compiler's type names.
  template <class F>
  Engine& bind_fn(const std::string& name, F f) {
    using S = detail::sig<std::decay_t<F>>;
    return bind_fn_impl(name, std::move(f), static_cast<typename S::template apply<Tag>*>(nullptr));
  }

  // The snippet sees the free function `R name(C& self, A... args)` (`const C&` for a const member
  // function) that calls the member function. Use it for members the host binary does not export
  // (see "native member calls" in docs/notes/eval.md); with an exported member `obj.m(args)` works as is.
  template <class C, class R, class... A>
  Engine& bind_method(const std::string& name, R (C::*m)(A...)) {
    return bind_fn(name, [m](C& self, A... a) -> R { return (self.*m)(static_cast<A&&>(a)...); });
  }
  template <class C, class R, class... A>
  Engine& bind_method(const std::string& name, R (C::*m)(A...) const) {
    return bind_fn(name, [m](const C& self, A... a) -> R { return (self.*m)(static_cast<A&&>(a)...); });
  }

  Engine& unbind(const std::string& name);

  // ---- evaluation ----------------------------------------------------------------------------
  // Statements; `return` gives the value. A snippet with no `return` whose last statement is a bare
  // expression ("a + b", "x = 3; x * 2") returns that expression. R must be a non-reference type
  // that is move or copy constructible; the value is converted from the snippet's return value.
  template <class R>
  R eval(const std::string& code) {
    if constexpr (std::is_void_v<R>) {
      run(code, std::string(), nullptr);
    } else {
      static_assert(!std::is_reference_v<R>, "eval<R>: R must not be a reference");
      return take<R>(code, detail::type_name_of<R>());
    }
  }
  // Same, with R spelled by the caller.
  template <class R>
  R eval(const std::string& code, const std::string& r_type) {
    static_assert(!std::is_void_v<R> && !std::is_reference_v<R>, "eval<R>(code, type)");
    return take<R>(code, r_type);
  }
  void eval_void(const std::string& code) { run(code, std::string(), nullptr); }

  // ---- introspection (for tests and debugging) -----------------------------------------------
  // The translation unit eval would compile for this code and result type ("" for void).
  std::string generate(const std::string& code, const std::string& r_type) const;
  // Number of compiler runs this engine has started / shared objects it has loaded.
  unsigned compiles() const;
  unsigned loads() const;
  const std::string& cache_dir() const;

 private:
  template <class... T>
  struct Tag {};
  template <class F, class R, class... A>
  Engine& bind_fn_impl(const std::string& name, F f, Tag<R, A...>*) {
    struct Thunk {
      static R call(void* st, A... a) { return (*static_cast<F*>(st))(static_cast<A&&>(a)...); }
    };
    std::unique_ptr<void, void (*)(void*)> state(new F(std::move(f)), +[](void* p) { delete static_cast<F*>(p); });
    void* raw = state.get();
    std::vector<std::string> args;
    (args.push_back(detail::type_name_of<A>()), ...);
    return bind_function(name, detail::type_name_of<R>(), args, reinterpret_cast<void*>(&Thunk::call),
                         raw, std::move(state));
  }

  // Runs the snippet with the result constructed in heap storage (operator new: no alignas, which cproc rejects).
  template <class R>
  R take(const std::string& code, const std::string& r_type) {
    static_assert(alignof(R) <= alignof(std::max_align_t), "eval<R>: over-aligned result type");
    struct Guard {
      void* mem;
      R* obj = nullptr;
      ~Guard() {
        if (obj) obj->~R();
        ::operator delete(mem);
      }
    } g{::operator new(sizeof(R))};
    run(code, r_type, g.mem);
    g.obj = static_cast<R*>(g.mem);
    return static_cast<R&&>(*g.obj);
  }

  Engine& bind_ref(const std::string& name, const std::string& type, void* addr);
  Engine& bind_function(const std::string& name, const std::string& ret, const std::vector<std::string>& args,
                        void* thunk, void* state, std::unique_ptr<void, void (*)(void*)> keep);
  void run(const std::string& code, const std::string& r_type, void* result);

  struct Impl;
  std::unique_ptr<Impl> p_;
};

}  // namespace nfceval
