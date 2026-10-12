// nfcpoly: evaluate scripts of other languages from C++ and share objects with them, GraalVM-polyglot style.
// Languages: Ruby (mruby), Lua, Python and JavaScript. Each is a backend (nfcpoly_mruby.cpp, nfcpoly_lua.cpp, nfcpoly_python.cpp,
// nfcpoly_js.cpp) that registers itself when linked in; this header and nfcpoly.cpp are the language-neutral core and include
// no interpreter header.
//
//   nfcpoly::Context ctx;
//   ctx.def_class<Vec3>("Vec3").ctor<double, double, double>().field("x", &Vec3::x).method("len2", &Vec3::len2);
//   Vec3 pos{1, 2, 3};
//   ctx.bind("pos", pos);                             // `pos` in a script is this very object, not a copy
//   ctx.bind_fn("scale", &scale);                     // `scale(2.0)` calls the C++ function
//   int r = ctx.eval<int>("ruby", "pos.x * scale(2.0)");
//   double d = ctx.eval<double>("lua", "pos.x * scale(2.0)");        // the same bindings, in Lua
//   double e = ctx.eval<double>("python", "pos.x * scale(2.0)");     // and in Python
//   double f = ctx.eval<double>("js", "pos.x * scale(2.0)");         // and in JavaScript
//
// A C++ exception thrown by a bound function is a script error to the script; an uncaught script error reaches the host
// as nfcpoly::ScriptError, or, when it carries a host exception that nothing rescued, as that very C++ exception.
// See docs/notes/poly.md. There is no sandbox and no time limit: a script runs in the host process with the host's
// privileges. A Context is not thread safe.
#pragma once
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

namespace nfcpoly {

// ---- errors -------------------------------------------------------------------------------------------------
// Base of every error the library reports itself (a bound function's own exceptions are not derived from it).
struct Error : std::runtime_error {
  using std::runtime_error::runtime_error;
};
// eval was asked for a language that is not linked in.
struct UnsupportedLanguage : Error {
  using Error::Error;
};
// The script did not parse. what(): "SyntaxError: message" (the script language's own wording of the message).
struct SyntaxError : Error {
  using Error::Error;
};
// A value could not be converted to the requested C++ type (wrong script type, out of range, class not registered).
struct ConversionError : Error {
  using Error::Error;
};
// A script error nothing rescued. what(): "ClassName: message".
class ScriptError : public Error {
 public:
  ScriptError(std::string cls, std::string msg, std::vector<std::string> backtrace, const void* owner,
              unsigned long serial)
      : Error(cls + ": " + msg), cls_(std::move(cls)), msg_(std::move(msg)), bt_(std::move(backtrace)),
        owner_(owner), serial_(serial) {}
  const std::string& class_name() const { return cls_; }   // "ArgumentError" (Ruby), "ValueError" (Python), "LuaError"
  const std::string& message() const { return msg_; }
  const std::vector<std::string>& backtrace() const { return bt_; }
  // Identify the script error object this was made from, so that a bound function that lets it escape re-raises that
  // very object into the script (each backend keeps the last one).
  const void* owner() const { return owner_; }
  unsigned long serial() const { return serial_; }

 private:
  std::string cls_, msg_;
  std::vector<std::string> bt_;
  const void* owner_;
  unsigned long serial_;
};

class Context;
class Value;
template <class T>
class ClassBuilder;

namespace detail {

struct Impl;   // the context's guts, nfcpoly.cpp
struct Lang;   // one language backend, nfcpoly_lang.hpp
struct Callable;

template <class... T>
struct Tag {};

// A unique address per type, without RTTI.
template <class T>
struct TypeTag {
  static const char tag;
};
template <class T>
const char TypeTag<T>::tag = 0;
template <class T>
const void* type_key() {
  return &TypeTag<std::remove_cv_t<T>>::tag;
}

// A C++ object the scripts co-own: the object goes away when the last script wrapper and the last Var/Value are gone.
struct Owned {
  void* p;
  void (*del)(void*);
  long refs;
};
inline void owned_ref(Owned* o) { ++o->refs; }
inline void owned_unref(Owned* o) {
  if (--o->refs == 0) {
    o->del(o->p);
    delete o;
  }
}
template <class T>
void delete_object(void* p) {
  delete static_cast<T*>(p);
}

// A reference to a script value that the interpreter must not collect. The backend subclasses it. A handle outlives
// its Context safely: when the context goes away it is orphaned (lang becomes null) and only its memory remains.
struct Handle {
  long refs = 1;
  Lang* lang;
  Impl* impl;
  Handle* prev = nullptr;
  Handle* next = nullptr;
  Handle(Lang* l, Impl* i);  // links into the context's list
  virtual ~Handle();         // unlinks
  virtual void orphan() = 0;  // the interpreter is closing: forget the script value without touching the interpreter
};
inline void handle_ref(Handle* h) { ++h->refs; }
inline void handle_unref(Handle* h) {
  if (--h->refs == 0) delete h;
}

struct ClassInfo {  // a registered C++ class; nfcpoly.cpp
  std::string name;
  const void* key = nullptr;
  Callable* ctor = nullptr;
  std::vector<std::pair<std::string, Callable*>> methods;  // receiver-first callables
  struct Prop {
    std::string name;
    Callable* get = nullptr;
    Callable* set = nullptr;
  };
  std::vector<Prop> props;
};

// A language-neutral script value. Script values that are not one of the plain kinds (arrays are converted on demand,
// see Lang::to_var) stay in the interpreter and are held by a Handle.
class Var {
 public:
  enum Kind : unsigned char { Nil, Bool, Int, Float, Str, Arr, Obj, Script };
  Var() : k_(Nil), b_(false), i_(0), d_(0), ci_(nullptr), p_(nullptr), own_(nullptr), h_(nullptr), src_(nullptr) {}
  Var(const Var& o)
      : k_(o.k_), b_(o.b_), i_(o.i_), d_(o.d_), s_(o.s_), a_(o.a_), ci_(o.ci_), p_(o.p_), own_(o.own_), h_(o.h_),
        src_(o.src_) {
    if (own_) owned_ref(own_);
    if (h_) handle_ref(h_);
  }
  Var(Var&& o) noexcept
      : k_(o.k_), b_(o.b_), i_(o.i_), d_(o.d_), s_(std::move(o.s_)), a_(std::move(o.a_)), ci_(o.ci_), p_(o.p_),
        own_(o.own_), h_(o.h_), src_(o.src_) {
    o.k_ = Nil;
    o.own_ = nullptr;
    o.h_ = nullptr;
  }
  Var& operator=(Var o) noexcept {
    swap(o);
    return *this;
  }
  ~Var() {
    if (own_) owned_unref(own_);
    if (h_) handle_unref(h_);
  }
  void swap(Var& o) noexcept {
    std::swap(k_, o.k_);
    std::swap(b_, o.b_);
    std::swap(i_, o.i_);
    std::swap(d_, o.d_);
    s_.swap(o.s_);
    a_.swap(o.a_);
    std::swap(ci_, o.ci_);
    std::swap(p_, o.p_);
    std::swap(own_, o.own_);
    std::swap(h_, o.h_);
    std::swap(src_, o.src_);
  }

  static Var boolean(bool b) { Var v; v.k_ = Bool; v.b_ = b; return v; }
  static Var integer(long long i) { Var v; v.k_ = Int; v.i_ = i; return v; }
  static Var real(double d) { Var v; v.k_ = Float; v.d_ = d; return v; }
  static Var string(std::string s) { Var v; v.k_ = Str; v.s_ = std::move(s); return v; }
  static Var array(std::vector<Var> a) { Var v; v.k_ = Arr; v.a_ = std::move(a); return v; }
  // A registered C++ object. own may be null (the host owns it); a non-null own gets a reference.
  static Var object(ClassInfo* ci, void* p, Owned* own) {
    Var v;
    v.k_ = Obj;
    v.ci_ = ci;
    v.p_ = p;
    v.own_ = own;
    if (own) owned_ref(own);
    return v;
  }
  // A script value kept in the interpreter; adopts the caller's reference to h.
  static Var script(Handle* h) { Var v; v.k_ = Script; v.h_ = h; v.src_ = h->lang; return v; }

  Kind kind() const { return k_; }
  bool b() const { return b_; }
  long long i() const { return i_; }
  double d() const { return d_; }
  const std::string& s() const { return s_; }
  const std::vector<Var>& a() const { return a_; }
  ClassInfo* ci() const { return ci_; }
  void* ptr() const { return p_; }
  Owned* owned() const { return own_; }
  Handle* handle() const { return h_; }
  Lang* src() const { return src_; }          // the language this value came from, null if it was made in C++
  void set_src(Lang* l) { src_ = l; }
  const char* kind_name() const;              // "nil", "boolean", "integer", ... (nfcpoly.cpp)

 private:
  Kind k_;
  bool b_;
  long long i_;
  double d_;
  std::string s_;
  std::vector<Var> a_;
  ClassInfo* ci_;
  void* p_;
  Owned* own_;
  Handle* h_;
  Lang* src_;
};

// One bound function or method. invoke gets the receiver (null for a plain function) and exactly arity() arguments;
// the backend's trampoline has checked the count, and turns every C++ exception that leaves invoke into a script error.
struct Callable {
  Impl* impl = nullptr;
  virtual ~Callable() {}
  virtual int arity() const = 0;
  virtual bool wants_self() const { return false; }  // true for methods: invoke gets the receiver
  virtual Var invoke(const Var* self, const Var* args) = 0;
};

// ---- implemented in nfcpoly.cpp -------------------------------------------------------------------------------
ClassInfo* find_class(Impl* impl, const void* key);
std::string class_name_hint(const void* key);  // the script name a type was registered under, for messages
[[noreturn]] void conversion_error(const Var& v, const char* want);
[[noreturn]] void range_error(const char* what);
[[noreturn]] void unregistered_class(const void* key);
[[noreturn]] void empty_value();
Var deep(const Var& v);                         // a Script handle converted to plain kinds where it can be; else v
void declare_fn(Impl* impl, const std::string& name, std::unique_ptr<Callable> c);
void declare_value(Impl* impl, const std::string& name, const Var& v);
void declare_variable(Impl* impl, const std::string& name, std::unique_ptr<Callable> get, std::unique_ptr<Callable> set);
ClassInfo* declare_class(Impl* impl, const void* key, const std::string& name);
void declare_method(Impl* impl, ClassInfo* ci, const std::string& name, std::unique_ptr<Callable> c);
void declare_prop(Impl* impl, ClassInfo* ci, const std::string& name, std::unique_ptr<Callable> get,
                  std::unique_ptr<Callable> set);
void declare_ctor(Impl* impl, ClassInfo* ci, std::unique_ptr<Callable> c);
Var eval_in(Impl* impl, std::string_view language, std::string_view code);
Var call_in(const Var& target, const std::string& method, const std::vector<Var>& args);
std::string inspect_of(const Var& v);
std::string type_name_of(const Var& v);
bool is_array_value(const Var& v);
Impl* impl_for(const Var& v);  // the context a script value came from; throws if it has none or it is gone

// ---- which C++ types are "values" (converted by copy) and which are registered classes (shared by reference) -----
template <class T>
struct is_vector : std::false_type {};
template <class T, class A>
struct is_vector<std::vector<T, A>> : std::true_type {};
template <class T>
struct is_optional : std::false_type {};
template <class T>
struct is_optional<std::optional<T>> : std::true_type {};
template <class D>
inline constexpr bool is_cstr_v = std::is_same_v<D, const char*> || std::is_same_v<D, char*>;
template <class D>
inline constexpr bool is_value_like_v = std::is_arithmetic_v<D> || std::is_same_v<D, std::string> ||
                                        std::is_same_v<D, std::string_view> || is_vector<D>::value ||
                                        is_optional<D>::value || std::is_same_v<D, Value> || is_cstr_v<D>;
template <class T>
using plain_t = std::decay_t<T>;  // also turns a string literal's array type into const char*

}  // namespace detail

// ---- a script value ------------------------------------------------------------------------------------------
// A handle to a script value, kept alive for as long as it exists. Copyable. Safe to keep after its Context is gone
// (it then only holds plain values and can no longer call into the interpreter).
class Value {
 public:
  Value() {}
  explicit Value(detail::Var v) : v_(std::move(v)) {}

  bool is_nil() const { return v_.kind() == detail::Var::Nil; }
  bool is_bool() const { return v_.kind() == detail::Var::Bool; }
  bool is_int() const { return v_.kind() == detail::Var::Int; }
  bool is_float() const { return v_.kind() == detail::Var::Float; }
  bool is_string() const { return v_.kind() == detail::Var::Str; }
  bool is_array() const { return v_.kind() == detail::Var::Arr || detail::is_array_value(v_); }
  std::string class_name() const { return detail::type_name_of(v_); }  // the script's name of its type
  std::string inspect() const { return detail::inspect_of(v_); }       // the script's own text for it

  // Converts to T: bool, integers (range checked), float, double, std::string, std::vector<T>, std::optional<T> (nil is
  // nullopt), Value, or a registered class by value (a copy), by reference (T&) or by pointer. Throws ConversionError.
  // A std::string_view result would dangle, so it is refused.
  template <class T>
  T as() const;

  // Calls the script method NAME on this value. Arguments are converted like bound function results: values by copy, an
  // lvalue class object by reference, an rvalue class object as a new object the script owns. Throws ScriptError (or the
  // host exception a bound function threw and nothing rescued).
  template <class... A>
  Value call(const std::string& name, A&&... args) const;

  // Calls the value itself: a Ruby Proc (its `call`), a Lua function, a Python callable. Same arguments and errors as call.
  template <class... A>
  Value execute(A&&... args) const {
    return call(std::string(), std::forward<A>(args)...);
  }

  const detail::Var& var() const { return v_; }

 private:
  detail::Var v_;
};

namespace detail {

template <class D, class = void>
struct Conv;

template <>
struct Conv<bool> {
  static Var to(bool b) { return Var::boolean(b); }
  static bool from(const Var& v) {
    if (v.kind() == Var::Bool) return v.b();
    conversion_error(v, "true or false");
  }
};

template <class I>
struct Conv<I, std::enable_if_t<std::is_integral_v<I> && !std::is_same_v<I, bool>>> {
  static Var to(I x) {
    if constexpr (std::is_unsigned_v<I>) {
      if (static_cast<unsigned long long>(x) > static_cast<unsigned long long>(std::numeric_limits<long long>::max()))
        range_error("integer does not fit the script's integer type");
    }
    return Var::integer(static_cast<long long>(x));
  }
  static I from(const Var& v) {
    long long i;
    if (v.kind() == Var::Int) {
      i = v.i();
    } else if (v.kind() == Var::Float && v.d() >= -9.2e18 && v.d() <= 9.2e18 &&
               v.d() == static_cast<double>(static_cast<long long>(v.d()))) {
      i = static_cast<long long>(v.d());  // 5.0 is losslessly the integer 5 (Lua's 10 / 2, Python's 10 / 2)
    } else {
      conversion_error(v, "integer");
    }
    if constexpr (std::is_signed_v<I>) {
      if (i < static_cast<long long>(std::numeric_limits<I>::min()) ||
          i > static_cast<long long>(std::numeric_limits<I>::max()))
        range_error("integer out of range for the requested C++ type");
    } else {
      if (i < 0 || static_cast<unsigned long long>(i) > static_cast<unsigned long long>(std::numeric_limits<I>::max()))
        range_error("integer out of range for the requested C++ type");
    }
    return static_cast<I>(i);
  }
};

template <class F>
struct Conv<F, std::enable_if_t<std::is_floating_point_v<F>>> {
  static Var to(F x) { return Var::real(static_cast<double>(x)); }
  static F from(const Var& v) {
    if (v.kind() == Var::Float) return static_cast<F>(v.d());
    if (v.kind() == Var::Int) return static_cast<F>(v.i());
    conversion_error(v, "number");
  }
};

template <>
struct Conv<std::string> {
  static Var to(const std::string& s) { return Var::string(s); }
  static std::string from(const Var& v) {
    if (v.kind() != Var::Str) conversion_error(v, "string");
    return v.s();
  }
};

// The view points into the Var holding the argument: valid during the call, so for parameters of bound functions only.
template <>
struct Conv<std::string_view> {
  static Var to(std::string_view s) { return Var::string(std::string(s)); }
  static std::string_view from(const Var& v) {
    if (v.kind() != Var::Str) conversion_error(v, "string");
    return std::string_view(v.s());
  }
};

template <class C>
struct Conv<C, std::enable_if_t<is_cstr_v<C>>> {
  static Var to(const char* s) { return s ? Var::string(std::string(s)) : Var(); }
  static const char* from(const Var& v) {  // valid during the call, like string_view
    if (v.kind() != Var::Str) conversion_error(v, "string");
    return v.s().c_str();
  }
};

template <>
struct Conv<Value> {
  static Var to(const Value& v) { return v.var(); }
  static Value from(const Var& v) { return Value(v); }
};

template <class T>
Var value_of_copy(Impl* impl, const T& x);
template <class D>
D from_var(const Var& v);

template <class T>
struct Conv<std::optional<T>> {
  static Var to(Impl* impl, const std::optional<T>& o) { return o ? value_of_copy<T>(impl, *o) : Var(); }
  static std::optional<T> from(const Var& v) {
    if (v.kind() == Var::Nil) return std::nullopt;
    return std::optional<T>(from_var<T>(v));
  }
};

template <class T, class A>
struct Conv<std::vector<T, A>> {
  static Var to(Impl* impl, const std::vector<T, A>& xs) {
    std::vector<Var> out;
    out.reserve(xs.size());
    for (const T& x : xs) out.push_back(value_of_copy<T>(impl, x));
    return Var::array(std::move(out));
  }
  static std::vector<T, A> from(const Var& v) {
    Var d = deep(v);
    if (d.kind() != Var::Arr) conversion_error(d, "array");
    std::vector<T, A> out;
    out.reserve(d.a().size());
    for (const Var& e : d.a()) out.push_back(from_var<T>(e));
    return out;
  }
};

// ---- registered classes ----------------------------------------------------------------------------------------
template <class T>
T* object_ptr(const Var& v, bool allow_nil) {
  if (allow_nil && v.kind() == Var::Nil) return nullptr;
  if (v.kind() == Var::Obj && v.ci()->key == type_key<T>()) return static_cast<T*>(v.ptr());
  conversion_error(v, class_name_hint(type_key<T>()).c_str());
  return nullptr;  // not reached
}

template <class T>
Var wrap_ref(Impl* impl, T* p) {
  ClassInfo* ci = find_class(impl, type_key<T>());
  if (!ci) unregistered_class(type_key<T>());
  return Var::object(ci, const_cast<std::remove_cv_t<T>*>(p), nullptr);
}
template <class T>
Var wrap_new(Impl* impl, T* p) {  // takes ownership of p
  ClassInfo* ci = find_class(impl, type_key<T>());
  if (!ci) {
    delete p;
    unregistered_class(type_key<T>());
  }
  Owned* o = new Owned{p, &delete_object<T>, 1};
  Var v = Var::object(ci, p, o);
  owned_unref(o);
  return v;
}

template <class D>
Var value_of_copy(Impl* impl, const D& x) {
  if constexpr (is_value_like_v<D>) {
    if constexpr (is_vector<D>::value || is_optional<D>::value) return Conv<D>::to(impl, x);
    else return Conv<D>::to(x);
  } else {
    return wrap_new<D>(impl, new D(x));
  }
}

template <class D>
D from_var(const Var& v) {
  if constexpr (is_value_like_v<D>) {
    static_assert(!std::is_same_v<D, std::string_view> && !is_cstr_v<D>,
                  "a view into the script's string would dangle; use std::string");
    return Conv<D>::from(v);
  } else {
    return D(*object_ptr<D>(v, false));
  }
}

// A script value for a host value of any type: values by copy, class objects by reference (lvalue or pointer) or as a
// new object the script owns (rvalue).
template <class T>
Var to_var(Impl* impl, T&& x) {
  using D = plain_t<T>;
  if constexpr (std::is_void_v<D>) {
    return Var();
  } else if constexpr (std::is_pointer_v<D> && !is_cstr_v<D>) {
    using P = std::remove_cv_t<std::remove_pointer_t<D>>;
    return x ? wrap_ref<P>(impl, x) : Var();
  } else if constexpr (is_value_like_v<D>) {
    if constexpr (is_vector<D>::value || is_optional<D>::value) return Conv<D>::to(impl, x);
    else return Conv<D>::to(x);
  } else if constexpr (std::is_lvalue_reference_v<T>) {
    return wrap_ref<D>(impl, &x);
  } else {
    return wrap_new<D>(impl, new D(std::forward<T>(x)));
  }
}

// An argument of a bound function. T& and const T& (class types) refer to the object in the script's wrapper; T* likewise,
// nil giving nullptr; everything else is converted by value.
template <class A>
decltype(auto) arg_from(const Var& v) {
  using D = plain_t<A>;
  if constexpr (std::is_pointer_v<D> && !is_cstr_v<D>) {
    return object_ptr<std::remove_pointer_t<D>>(v, true);
  } else if constexpr (std::is_lvalue_reference_v<A> && !is_value_like_v<D>) {
    return static_cast<A>(*object_ptr<D>(v, false));
  } else if constexpr (std::is_same_v<D, std::string_view> || is_cstr_v<D>) {
    return Conv<D>::from(v);
  } else {
    return from_var<D>(v);
  }
}

// ---- callables -------------------------------------------------------------------------------------------------
template <class F, class = void>
struct fn_sig;
template <class R, class... A>
struct fn_sig<R(A...), void> {
  using tag = Tag<R, A...>;
};
template <class R, class... A>
struct fn_sig<R (*)(A...), void> : fn_sig<R(A...)> {};
template <class R, class... A>
struct fn_sig<R (*)(A...) noexcept, void> : fn_sig<R(A...)> {};
template <class C, class R, class... A>
struct fn_sig<R (C::*)(A...) const, void> : fn_sig<R(A...)> {};
template <class C, class R, class... A>
struct fn_sig<R (C::*)(A...) const noexcept, void> : fn_sig<R(A...)> {};
template <class C, class R, class... A>
struct fn_sig<R (C::*)(A...), void> : fn_sig<R(A...)> {};
template <class C, class R, class... A>
struct fn_sig<R (C::*)(A...) noexcept, void> : fn_sig<R(A...)> {};
template <class F>
struct fn_sig<F, std::void_t<decltype(&F::operator())>> : fn_sig<decltype(&F::operator())> {};

// Self: the first parameter of F is the script's receiver, the others come from the arguments.
template <bool Self, class F, class R, class... A>
class FnCallable : public Callable {
 public:
  explicit FnCallable(F f) : f_(std::move(f)) {}
  int arity() const override { return static_cast<int>(sizeof...(A)) - (Self ? 1 : 0); }
  bool wants_self() const override { return Self; }
  Var invoke(const Var* self, const Var* args) override { return call(self, args, std::index_sequence_for<A...>{}); }

 private:
  template <std::size_t I>
  static const Var& pick(const Var* self, const Var* args) {
    if constexpr (Self) {
      if constexpr (I == 0) return *self;
      else return args[I - 1];
    } else {
      return args[I];
    }
  }
  template <std::size_t... I>
  Var call(const Var* self, const Var* args, std::index_sequence<I...>) {
    if constexpr (std::is_void_v<R>) {
      f_(arg_from<A>(pick<I>(self, args))...);
      return Var();
    } else {
      return to_var<R>(impl, f_(arg_from<A>(pick<I>(self, args))...));
    }
  }
  F f_;
};

template <bool Self, class F, class R, class... A>
std::unique_ptr<Callable> make_callable_impl(Impl* impl, F f, Tag<R, A...>*) {
  std::unique_ptr<Callable> c(new FnCallable<Self, F, R, A...>(std::move(f)));
  c->impl = impl;
  return c;
}
template <bool Self, class F>
std::unique_ptr<Callable> make_callable(Impl* impl, F f) {
  using S = fn_sig<std::decay_t<F>>;
  return make_callable_impl<Self>(impl, std::move(f), static_cast<typename S::tag*>(nullptr));
}

template <class C, class R, class... A>
auto member_lambda(R (C::*m)(A...)) {
  return [m](C& self, A... a) -> R { return (self.*m)(static_cast<A&&>(a)...); };
}
template <class C, class R, class... A>
auto member_lambda(R (C::*m)(A...) const) {
  return [m](const C& self, A... a) -> R { return (self.*m)(static_cast<A&&>(a)...); };
}
template <class C, class R, class... A>
auto member_lambda(R (C::*m)(A...) noexcept) {
  return [m](C& self, A... a) -> R { return (self.*m)(static_cast<A&&>(a)...); };
}
template <class C, class R, class... A>
auto member_lambda(R (C::*m)(A...) const noexcept) {
  return [m](const C& self, A... a) -> R { return (self.*m)(static_cast<A&&>(a)...); };
}

// The constructor of a bound class: builds a T from the arguments and returns it as a new object the script owns.
template <class T, class... A>
class CtorCallable : public Callable {
 public:
  int arity() const override { return static_cast<int>(sizeof...(A)); }
  Var invoke(const Var*, const Var* args) override { return make(args, std::index_sequence_for<A...>{}); }

 private:
  template <std::size_t... I>
  Var make(const Var* args, std::index_sequence<I...>) {
    return wrap_new<T>(impl, new T(arg_from<A>(args[I])...));
  }
};

}  // namespace detail

// ---- registering a C++ class ----------------------------------------------------------------------------------
template <class T>
class ClassBuilder {
 public:
  // Name.new(args...) constructs a T the script owns. Without ctor() the class has no constructor.
  template <class... A>
  ClassBuilder& ctor() {
    std::unique_ptr<detail::Callable> c(new detail::CtorCallable<T, A...>);
    c->impl = impl_;
    detail::declare_ctor(impl_, ci_, std::move(c));
    return *this;
  }
  // A member function: obj.name(args...). Overloaded members need a cast: static_cast<R (T::*)(A...)>(&T::f).
  template <class M>
  ClassBuilder& method(const std::string& name, M m) {
    detail::declare_method(impl_, ci_, name, detail::make_callable<true>(impl_, detail::member_lambda(m)));
    return *this;
  }
  // A function whose first parameter is the object (T&, const T& or T*): obj.name(args...).
  template <class F>
  ClassBuilder& method_fn(const std::string& name, F f) {
    detail::declare_method(impl_, ci_, name, detail::make_callable<true>(impl_, std::move(f)));
    return *this;
  }
  // obj.name reads the member, obj.name = v writes it (not for const members). A member of a registered class type is
  // shared by reference with its owner; any other type is copied.
  template <class M>
  ClassBuilder& field(const std::string& name, M T::*p) {
    using V = std::remove_cv_t<M>;
    std::unique_ptr<detail::Callable> get, set;
    if constexpr (detail::is_value_like_v<V>) {
      get = detail::make_callable<true>(impl_, [p](const T& s) -> V { return s.*p; });
      if constexpr (!std::is_const_v<M> && std::is_copy_assignable_v<V>)
        set = detail::make_callable<true>(impl_, [p](T& s, V v) { s.*p = std::move(v); });
    } else {
      get = detail::make_callable<true>(impl_, [p](T& s) -> V& { return s.*p; });
      if constexpr (!std::is_const_v<M> && std::is_copy_assignable_v<V>)
        set = detail::make_callable<true>(impl_, [p](T& s, const V& v) { s.*p = v; });
    }
    detail::declare_prop(impl_, ci_, name, std::move(get), std::move(set));
    return *this;
  }

 private:
  friend class Context;
  ClassBuilder(detail::Impl* impl, detail::ClassInfo* ci) : impl_(impl), ci_(ci) {}
  detail::Impl* impl_;
  detail::ClassInfo* ci_;
};

// ---- the context -----------------------------------------------------------------------------------------------
class Context {
 public:
  Context();
  ~Context();
  Context(const Context&) = delete;
  Context& operator=(const Context&) = delete;

  // The languages eval accepts: the backends linked into the program ("ruby" (alias "mruby"), "lua", "python", "js"). A
  // language's interpreter is started on its first use; everything declared before that is replayed into it.
  static std::vector<std::string> languages();

  // ---- sharing host things with scripts (every language sees them) ----
  // Registers T under a script class NAME (a constant such as "Vec3"). A class must be registered before an object of it
  // is bound or crosses the boundary. Subclassing in C++ is not tracked: a Derived is not accepted as a Base.
  template <class T>
  ClassBuilder<T> def_class(const std::string& name) {
    static_assert(!std::is_const_v<T> && !detail::is_value_like_v<T> && std::is_class_v<T>,
                  "def_class<T>: T must be a class type that is not converted by value");
    detail::ClassInfo* ci = detail::declare_class(impl(), detail::type_key<T>(), name);
    return ClassBuilder<T>(impl(), ci);
  }

  // A script sees `name` as a global: a registered class object is the object itself (the same wrapper on every read,
  // the object must outlive the context); an arithmetic or std::string variable is read live and can be written back
  // (Ruby: `self.name = v`; Lua: `name = v`; Python: `name = v` at the top level). NAME is a lower-case identifier.
  template <class T>
  Context& bind(const std::string& name, T& obj) {
    using D = std::remove_cv_t<T>;
    if constexpr (detail::is_value_like_v<D>) {
      static_assert(std::is_arithmetic_v<D> || std::is_same_v<D, std::string>,
                    "bind: arithmetic, std::string or a registered class object; use set() for other values");
      T* p = &obj;
      std::unique_ptr<detail::Callable> get = detail::make_callable<false>(impl(), [p]() -> D { return *p; });
      std::unique_ptr<detail::Callable> set;
      if constexpr (!std::is_const_v<T>) set = detail::make_callable<false>(impl(), [p](D v) { *p = std::move(v); });
      detail::declare_variable(impl(), name, std::move(get), std::move(set));
    } else {
      static_assert(!std::is_const_v<T>, "bind: a const class object cannot be shared (scripts can call any method)");
      detail::declare_value(impl(), name, detail::wrap_ref<D>(impl(), &obj));
    }
    return *this;
  }

  // A script sees `name` as a global holding a copy of VALUE (a class object is copied into a new script-owned object;
  // a Value is shared if it belongs to the same language and copied by value otherwise).
  template <class T>
  Context& set(const std::string& name, T&& value) {
    detail::declare_value(impl(), name, detail::value_of_copy<detail::plain_t<T>>(impl(), value));
    return *this;
  }

  // A script can call `name(args...)`. F is a function, function pointer, lambda or other callable with one
  // non-template call operator. Parameters: values by copy, registered classes by T&, const T& or T* (the script's
  // object), results likewise (T& and T* are shared, a T is a new script-owned object). Exact arity.
  template <class F>
  Context& bind_fn(const std::string& name, F f) {
    detail::declare_fn(impl(), name, detail::make_callable<false>(impl(), std::move(f)));
    return *this;
  }

  // ---- evaluation ----
  // Runs CODE and returns its value: Ruby the last expression, Python the last expression statement, Lua the chunk's
  // `return` value (a source that is a single expression is returned as is). Globals persist between calls; Ruby's
  // top-level locals do too.
  Value eval_value(std::string_view language, std::string_view code) {
    return Value(detail::eval_in(impl(), language, code));
  }
  template <class R>
  R eval(std::string_view language, std::string_view code) {
    static_assert(!std::is_reference_v<R> && !(std::is_pointer_v<R> && !detail::is_cstr_v<R>),
                  "eval<R>: a reference or pointer into a script object would dangle once the result Value is gone; "
                  "use eval_value() and keep the Value, or eval<T> for a copy");
    if constexpr (std::is_void_v<R>) {
      eval_value(language, code);
    } else {
      return eval_value(language, code).template as<R>();
    }
  }
  void eval_void(std::string_view language, std::string_view code) { eval_value(language, code); }

  detail::Impl* impl() const { return p_.get(); }  // for the language-specific accessors (nfcpoly_mruby.hpp, ...)

 private:
  std::unique_ptr<detail::Impl> p_;
};

// ---- Value templates -------------------------------------------------------------------------------------------
template <class T>
T Value::as() const {
  using D = detail::plain_t<T>;
  if constexpr (std::is_pointer_v<D> && !detail::is_cstr_v<D>) {
    return detail::object_ptr<std::remove_pointer_t<D>>(v_, true);
  } else if constexpr (std::is_lvalue_reference_v<T> && !detail::is_value_like_v<D>) {
    return *detail::object_ptr<D>(v_, false);
  } else {
    static_assert(!std::is_reference_v<T>, "Value::as<T&>: only for registered classes");
    return detail::from_var<D>(v_);
  }
}

template <class... A>
Value Value::call(const std::string& name, A&&... args) const {
  detail::Impl* impl = detail::impl_for(v_);
  std::vector<detail::Var> argv;
  argv.reserve(sizeof...(A));
  (argv.push_back(detail::to_var<A>(impl, std::forward<A>(args))), ...);
  return Value(detail::call_in(v_, name, argv));
}

}  // namespace nfcpoly
