// nfcpoly: evaluate scripts of another language from C++ and share objects with them, GraalVM-polyglot style.
// The language is mruby (Ruby), embedded as a library built with C++ exceptions (scripts/setup-poly.sh).
//
//   nfcpoly::Context ctx;
//   ctx.def_class<Vec3>("Vec3").ctor<double, double, double>().field("x", &Vec3::x).method("len2", &Vec3::len2);
//   Vec3 pos{1, 2, 3};
//   ctx.bind("pos", pos);                             // `pos` in a script is this very object, not a copy
//   ctx.bind_fn("scale", &scale);                     // `scale(2.0)` calls the C++ function
//   int r = ctx.eval<int>("ruby", "pos.x * scale(2.0)");
//
// A C++ exception thrown by a bound function unwinds the script like a Ruby exception, and an uncaught script
// exception reaches the host as nfcpoly::ScriptError (or, when it carries a host exception that nothing rescued,
// as that very C++ exception). See docs/notes/poly.md. Build: nfcxx -I lib/poly -I build/poly/<backend>/include
// host.cpp lib/poly/nfcpoly.cpp build/poly/<backend>/lib/libmruby.a -o host
//
// There is no sandbox and no time limit: a script runs in the host process with the host's privileges.
// A Context is not thread safe. Values and the objects bound to a Context must not outlive it.
#pragma once
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>

namespace nfcpoly {

// ---- errors -------------------------------------------------------------------------------------------------
// Base of every error the library reports itself (a bound function's own exceptions are not derived from it).
struct Error : std::runtime_error {
  using std::runtime_error::runtime_error;
};
// eval was asked for a language this library does not have.
struct UnsupportedLanguage : Error {
  using Error::Error;
};
// The script did not parse. what(): "SyntaxError: line N: message".
struct SyntaxError : Error {
  using Error::Error;
};
// A value could not be converted to the requested C++ type (wrong script type, out of range, class not registered).
struct ConversionError : Error {
  using Error::Error;
};
// A script exception nothing rescued. what(): "ClassName: message".
class ScriptError : public Error {
 public:
  ScriptError(std::string cls, std::string msg, std::vector<std::string> backtrace, const void* owner,
              unsigned long serial)
      : Error(cls + ": " + msg), cls_(std::move(cls)), msg_(std::move(msg)), bt_(std::move(backtrace)),
        owner_(owner), serial_(serial) {}
  const std::string& class_name() const { return cls_; }   // "ArgumentError"
  const std::string& message() const { return msg_; }
  const std::vector<std::string>& backtrace() const { return bt_; }
  // Identify the script exception object this was made from, so that a bound function that lets it escape
  // re-raises that very object into the script (Context::Impl keeps the last one).
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

struct Impl;       // the context's guts, nfcpoly.cpp
struct ClassInfo;  // a registered C++ class, nfcpoly.cpp

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

// ---- implemented in nfcpoly.cpp -------------------------------------------------------------------------------
mrb_state* state_of(Impl* impl);
void root_add(Impl* impl, mrb_value v);
void root_del(Impl* impl, mrb_value v);
ClassInfo* find_class(mrb_state* mrb, const void* key);
// The object inside a script wrapper of the class; throws ConversionError for another type or an uninitialised
// object. nil gives nullptr when allow_nil.
void* unwrap_object(mrb_state* mrb, ClassInfo* ci, mrb_value v, bool allow_nil);
mrb_value wrap_borrowed(mrb_state* mrb, ClassInfo* ci, void* p);  // the C++ object stays the host's
mrb_value wrap_owned(mrb_state* mrb, ClassInfo* ci, void* p);     // the script's GC deletes it (class deleter)
[[noreturn]] void conversion_error(mrb_state* mrb, mrb_value v, const char* want);  // "expected WANT, got Class"
[[noreturn]] void range_error(const char* what);
[[noreturn]] void unregistered_class(const char* what);
Value make_value(Impl* impl, mrb_value v);
Value call_method(Impl* impl, mrb_value self, const std::string& name, const mrb_value* argv, mrb_int argc);

// One bound function or method. invoke gets the script's receiver and arguments; the trampoline in nfcpoly.cpp has
// already checked argc == arity(), and turns every C++ exception that leaves invoke into a script exception.
struct Callable {
  virtual ~Callable() {}
  virtual int arity() const = 0;
  virtual mrb_value invoke(mrb_state* mrb, mrb_value self, mrb_int argc, const mrb_value* argv) = 0;
};
void define_global_fn(Impl* impl, const std::string& name, std::unique_ptr<Callable> c);
void define_global_value(Impl* impl, const std::string& name, mrb_value v);
ClassInfo* register_class(Impl* impl, const void* key, const std::string& name, void (*deleter)(mrb_state*, void*));
void define_method(Impl* impl, ClassInfo* ci, const std::string& name, std::unique_ptr<Callable> c);
void define_initializer(Impl* impl, ClassInfo* ci, std::unique_ptr<Callable> c);
void check_uninitialised(mrb_state* mrb, ClassInfo* ci, mrb_value self);  // raises a script TypeError
void init_owned(mrb_state* mrb, ClassInfo* ci, mrb_value self, void* p);

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

// Conv<D>::to / ::from for the value-like types. Specialisations follow the Value class (Conv<Value> needs it).
template <class D, class = void>
struct Conv;

template <class D>
mrb_value value_of_copy(mrb_state* mrb, const D& x);  // a value-like D is converted, a class is copied into a new object
template <class D>
D from_value(mrb_state* mrb, mrb_value v);            // by value; for a class, a copy of the script's object

}  // namespace detail

// ---- a script value ------------------------------------------------------------------------------------------
// A handle to a script value, kept alive for as long as it exists. Copyable. Must not outlive its Context.
class Value {
 public:
  Value() : impl_(nullptr), v_(mrb_nil_value()) {}
  Value(const Value& o) : impl_(o.impl_), v_(o.v_) { if (impl_) detail::root_add(impl_, v_); }
  Value(Value&& o) noexcept : impl_(o.impl_), v_(o.v_) { o.impl_ = nullptr; o.v_ = mrb_nil_value(); }
  Value& operator=(const Value& o) {
    if (this != &o) {
      Value t(o);
      swap(t);
    }
    return *this;
  }
  Value& operator=(Value&& o) noexcept {
    if (this != &o) {
      Value t(std::move(o));
      swap(t);
    }
    return *this;
  }
  ~Value() { if (impl_) detail::root_del(impl_, v_); }
  void swap(Value& o) noexcept {
    std::swap(impl_, o.impl_);
    std::swap(v_, o.v_);
  }

  bool is_nil() const { return mrb_nil_p(v_); }
  bool is_bool() const { return mrb_true_p(v_) || mrb_false_p(v_); }
  bool is_int() const { return mrb_integer_p(v_); }
  bool is_float() const { return mrb_float_p(v_); }
  bool is_string() const { return mrb_string_p(v_); }
  bool is_array() const { return mrb_array_p(v_); }
  std::string class_name() const;  // the script class, "Integer"
  std::string inspect() const;     // the script's inspect

  // Converts to T: bool, integers (range checked), float, double, std::string, std::vector<T>, std::optional<T>
  // (nil is nullopt), Value, or a registered class by value (a copy), by reference (T&, the object in the script's
  // wrapper) or by pointer. Throws ConversionError. A std::string_view result would dangle, so it is refused.
  template <class T>
  T as() const;

  // Calls the script method NAME on this value. Arguments are converted like bound function results: values by
  // copy, an lvalue class object by reference, an rvalue class object as a new object the script owns.
  // Throws ScriptError (or the host exception a bound function threw and nothing rescued).
  template <class... A>
  Value call(const std::string& name, A&&... args) const;

  mrb_value raw() const { return v_; }

 private:
  friend Value detail::make_value(detail::Impl*, mrb_value);
  Value(detail::Impl* impl, mrb_value v) : impl_(impl), v_(v) { if (impl_) detail::root_add(impl_, v_); }
  detail::Impl* impl_;
  mrb_value v_;
};

namespace detail {

[[noreturn]] void empty_value();
mrb_value cstr_value(mrb_state* mrb, const char* s);

template <>
struct Conv<bool> {
  static mrb_value to(mrb_state*, bool b) { return mrb_bool_value(b); }
  static bool from(mrb_state* mrb, mrb_value v) {
    if (mrb_true_p(v)) return true;
    if (mrb_false_p(v)) return false;
    conversion_error(mrb, v, "true or false");
  }
};

template <class I>
struct Conv<I, std::enable_if_t<std::is_integral_v<I> && !std::is_same_v<I, bool>>> {
  static mrb_value to(mrb_state* mrb, I x) {
    if constexpr (std::is_signed_v<I>) {
      if (static_cast<long long>(x) < static_cast<long long>(MRB_INT_MIN) ||
          static_cast<long long>(x) > static_cast<long long>(MRB_INT_MAX))
        range_error("integer does not fit the script's Integer");
    } else {
      if (static_cast<unsigned long long>(x) > static_cast<unsigned long long>(MRB_INT_MAX))
        range_error("integer does not fit the script's Integer");
    }
    return mrb_int_value(mrb, static_cast<mrb_int>(x));
  }
  static I from(mrb_state* mrb, mrb_value v) {
    if (!mrb_integer_p(v)) conversion_error(mrb, v, "Integer");
    long long i = static_cast<long long>(mrb_integer(v));
    if constexpr (std::is_signed_v<I>) {
      if (i < static_cast<long long>(std::numeric_limits<I>::min()) ||
          i > static_cast<long long>(std::numeric_limits<I>::max()))
        range_error("Integer out of range for the requested C++ type");
    } else {
      if (i < 0 || static_cast<unsigned long long>(i) > static_cast<unsigned long long>(std::numeric_limits<I>::max()))
        range_error("Integer out of range for the requested C++ type");
    }
    return static_cast<I>(i);
  }
};

template <class F>
struct Conv<F, std::enable_if_t<std::is_floating_point_v<F>>> {
  static mrb_value to(mrb_state* mrb, F x) { return mrb_float_value(mrb, static_cast<mrb_float>(x)); }
  static F from(mrb_state* mrb, mrb_value v) {
    if (mrb_float_p(v)) return static_cast<F>(mrb_float(v));
    if (mrb_integer_p(v)) return static_cast<F>(mrb_integer(v));
    conversion_error(mrb, v, "Float");
  }
};

template <>
struct Conv<std::string> {
  static mrb_value to(mrb_state* mrb, const std::string& s) { return mrb_str_new(mrb, s.data(), static_cast<mrb_int>(s.size())); }
  static std::string from(mrb_state* mrb, mrb_value v) {
    if (!mrb_string_p(v)) conversion_error(mrb, v, "String");
    return std::string(RSTRING_PTR(v), static_cast<std::size_t>(RSTRING_LEN(v)));
  }
};

// The view points into the script's string: valid only while that string lives, so it is for arguments of bound
// functions (the argument stays on the VM stack during the call) and never for results.
template <>
struct Conv<std::string_view> {
  static mrb_value to(mrb_state* mrb, std::string_view s) { return mrb_str_new(mrb, s.data(), static_cast<mrb_int>(s.size())); }
  static std::string_view from(mrb_state* mrb, mrb_value v) {
    if (!mrb_string_p(v)) conversion_error(mrb, v, "String");
    return std::string_view(RSTRING_PTR(v), static_cast<std::size_t>(RSTRING_LEN(v)));
  }
};

template <class C>
struct Conv<C, std::enable_if_t<is_cstr_v<C>>> {
  static mrb_value to(mrb_state* mrb, const char* s) { return cstr_value(mrb, s); }
};

template <>
struct Conv<Value> {
  static mrb_value to(mrb_state*, const Value& v) { return v.raw(); }
  static Value from(mrb_state* mrb, mrb_value v);  // nfcpoly.cpp: needs the context behind mrb
};

template <class T>
struct Conv<std::optional<T>> {
  static mrb_value to(mrb_state* mrb, const std::optional<T>& o) {
    return o ? value_of_copy<T>(mrb, *o) : mrb_nil_value();
  }
  static std::optional<T> from(mrb_state* mrb, mrb_value v) {
    if (mrb_nil_p(v)) return std::nullopt;
    return std::optional<T>(from_value<T>(mrb, v));
  }
};

template <class T, class A>
struct Conv<std::vector<T, A>> {
  static mrb_value to(mrb_state* mrb, const std::vector<T, A>& xs) {
    mrb_value ary = mrb_ary_new_capa(mrb, static_cast<mrb_int>(xs.size()));
    int ai = mrb_gc_arena_save(mrb);  // ary itself stays protected below this mark
    for (const T& x : xs) {
      mrb_ary_push(mrb, ary, value_of_copy<T>(mrb, x));
      mrb_gc_arena_restore(mrb, ai);
    }
    return ary;
  }
  static std::vector<T, A> from(mrb_state* mrb, mrb_value v) {
    if (!mrb_array_p(v)) conversion_error(mrb, v, "Array");
    std::vector<T, A> out;
    mrb_int n = RARRAY_LEN(v);
    out.reserve(static_cast<std::size_t>(n));
    for (mrb_int i = 0; i < n; ++i) out.push_back(from_value<T>(mrb, mrb_ary_entry(v, i)));
    return out;
  }
};

// ---- registered classes ----------------------------------------------------------------------------------------
template <class T>
T* object_ptr(mrb_state* mrb, mrb_value v, bool allow_nil) {
  ClassInfo* ci = find_class(mrb, type_key<T>());
  if (!ci) unregistered_class("class");
  return static_cast<T*>(unwrap_object(mrb, ci, v, allow_nil));
}
template <class T>
mrb_value wrap_ref(mrb_state* mrb, T* p) {
  ClassInfo* ci = find_class(mrb, type_key<T>());
  if (!ci) unregistered_class("class");
  return wrap_borrowed(mrb, ci, const_cast<std::remove_cv_t<T>*>(p));
}
template <class T>
mrb_value wrap_new(mrb_state* mrb, T* p) {  // takes ownership of p
  ClassInfo* ci = find_class(mrb, type_key<T>());
  if (!ci) {
    delete p;
    unregistered_class("class");
  }
  return wrap_owned(mrb, ci, p);
}

template <class D>
mrb_value value_of_copy(mrb_state* mrb, const D& x) {
  if constexpr (is_value_like_v<D>) {
    return Conv<D>::to(mrb, x);
  } else {
    return wrap_new<D>(mrb, new D(x));
  }
}

template <class D>
D from_value(mrb_state* mrb, mrb_value v) {
  if constexpr (is_value_like_v<D>) {
    static_assert(!std::is_same_v<D, std::string_view> && !is_cstr_v<D>,
                  "a view into the script's string would dangle; use std::string");
    return Conv<D>::from(mrb, v);
  } else {
    return D(*object_ptr<D>(mrb, v, false));
  }
}

// A script value for a host value of any type: values by copy, class objects by reference (lvalue or pointer) or as a
// new object the script owns (rvalue).
template <class T>
mrb_value to_value(mrb_state* mrb, T&& x) {
  using D = plain_t<T>;
  if constexpr (std::is_void_v<D>) {
    return mrb_nil_value();
  } else if constexpr (std::is_pointer_v<D> && !is_cstr_v<D>) {
    using P = std::remove_cv_t<std::remove_pointer_t<D>>;
    return x ? wrap_ref<P>(mrb, x) : mrb_nil_value();
  } else if constexpr (is_value_like_v<D>) {
    return Conv<D>::to(mrb, x);
  } else if constexpr (std::is_lvalue_reference_v<T>) {
    return wrap_ref<D>(mrb, &x);
  } else {
    return wrap_new<D>(mrb, new D(std::forward<T>(x)));
  }
}

// An argument of a bound function, from the script value. T& and const T& (class types) refer to the object in the
// script's wrapper; T* likewise, nil giving nullptr; everything else is converted by value.
template <class A>
decltype(auto) arg_from(mrb_state* mrb, mrb_value v) {
  using D = plain_t<A>;
  if constexpr (std::is_pointer_v<D> && !is_cstr_v<D>) {
    return object_ptr<std::remove_pointer_t<D>>(mrb, v, true);
  } else if constexpr (std::is_lvalue_reference_v<A> && !is_value_like_v<D>) {
    return static_cast<A>(*object_ptr<D>(mrb, v, false));
  } else if constexpr (std::is_same_v<D, std::string_view>) {
    return Conv<std::string_view>::from(mrb, v);
  } else {
    static_assert(!is_cstr_v<D>, "a const char* parameter is not supported; take std::string or std::string_view");
    return from_value<D>(mrb, v);
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
  mrb_value invoke(mrb_state* mrb, mrb_value self, mrb_int, const mrb_value* argv) override {
    return call(mrb, self, argv, std::index_sequence_for<A...>{});
  }

 private:
  template <std::size_t I>
  static mrb_value pick(mrb_value self, const mrb_value* argv) {
    if constexpr (Self) {
      if constexpr (I == 0) return self;
      else return argv[I - 1];
    } else {
      return argv[I];
    }
  }
  template <std::size_t... I>
  mrb_value call(mrb_state* mrb, mrb_value self, const mrb_value* argv, std::index_sequence<I...>) {
    if constexpr (std::is_void_v<R>) {
      f_(arg_from<A>(mrb, pick<I>(self, argv))...);
      return mrb_nil_value();
    } else {
      return to_value<R>(mrb, f_(arg_from<A>(mrb, pick<I>(self, argv))...));
    }
  }
  F f_;
};

template <bool Self, class F, class R, class... A>
std::unique_ptr<Callable> make_callable_impl(F f, Tag<R, A...>*) {
  return std::unique_ptr<Callable>(new FnCallable<Self, F, R, A...>(std::move(f)));
}
template <bool Self, class F>
std::unique_ptr<Callable> make_callable(F f) {
  using S = fn_sig<std::decay_t<F>>;
  return make_callable_impl<Self>(std::move(f), static_cast<typename S::tag*>(nullptr));
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

// `initialize` of a bound class: constructs a T from the arguments.
template <class T, class... A>
class CtorCallable : public Callable {
 public:
  explicit CtorCallable(ClassInfo* ci) : ci_(ci) {}
  int arity() const override { return static_cast<int>(sizeof...(A)); }
  mrb_value invoke(mrb_state* mrb, mrb_value self, mrb_int, const mrb_value* argv) override {
    check_uninitialised(mrb, ci_, self);
    return make(mrb, self, argv, std::index_sequence_for<A...>{});
  }

 private:
  template <std::size_t... I>
  mrb_value make(mrb_state* mrb, mrb_value self, const mrb_value* argv, std::index_sequence<I...>) {
    T* p = new T(arg_from<A>(mrb, argv[I])...);
    init_owned(mrb, ci_, self, p);
    return self;
  }
  ClassInfo* ci_;
};

template <class T>
void delete_object(mrb_state*, void* p) {
  delete static_cast<T*>(p);
}

}  // namespace detail

// ---- registering a C++ class ----------------------------------------------------------------------------------
template <class T>
class ClassBuilder {
 public:
  // Name.new(args...) constructs a T the script owns. Without ctor() the class has no constructor.
  template <class... A>
  ClassBuilder& ctor() {
    detail::define_initializer(impl_, ci_, std::unique_ptr<detail::Callable>(new detail::CtorCallable<T, A...>(ci_)));
    return *this;
  }
  // A member function: obj.name(args...). Overloaded members need a cast: static_cast<R (T::*)(A...)>(&T::f).
  template <class M>
  ClassBuilder& method(const std::string& name, M m) {
    detail::define_method(impl_, ci_, name, detail::make_callable<true>(detail::member_lambda(m)));
    return *this;
  }
  // A function whose first parameter is the object (T&, const T& or T*): obj.name(args...).
  template <class F>
  ClassBuilder& method_fn(const std::string& name, F f) {
    detail::define_method(impl_, ci_, name, detail::make_callable<true>(std::move(f)));
    return *this;
  }
  // obj.name reads the member, obj.name = v writes it (not for const members). A member of a registered class type is
  // shared by reference with its owner; any other type is copied.
  template <class M>
  ClassBuilder& field(const std::string& name, M T::*p) {
    using V = std::remove_cv_t<M>;
    if constexpr (detail::is_value_like_v<V>) {
      detail::define_method(impl_, ci_, name, detail::make_callable<true>([p](const T& s) -> V { return s.*p; }));
      if constexpr (!std::is_const_v<M> && std::is_copy_assignable_v<V>)
        detail::define_method(impl_, ci_, name + "=", detail::make_callable<true>([p](T& s, V v) { s.*p = std::move(v); }));
    } else {
      detail::define_method(impl_, ci_, name, detail::make_callable<true>([p](T& s) -> V& { return s.*p; }));
      if constexpr (!std::is_const_v<M> && std::is_copy_assignable_v<V>)
        detail::define_method(impl_, ci_, name + "=", detail::make_callable<true>([p](T& s, const V& v) { s.*p = v; }));
    }
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

  // The languages eval accepts: "ruby" (alias "mruby").
  static std::vector<std::string> languages();

  // ---- sharing host things with scripts ----
  // Registers T under a script class NAME (a constant such as "Vec3"). A class must be registered before an object
  // of it is bound or crosses the boundary. Subclassing in C++ is not tracked: a Derived is not accepted as a Base.
  template <class T>
  ClassBuilder<T> def_class(const std::string& name) {
    static_assert(!std::is_const_v<T> && !detail::is_value_like_v<T> && std::is_class_v<T>,
                  "def_class<T>: T must be a class type that is not converted by value");
    detail::ClassInfo* ci = detail::register_class(impl(), detail::type_key<T>(), name, &detail::delete_object<T>);
    return ClassBuilder<T>(impl(), ci);
  }

  // A script sees `name` as a global: a registered class object is the object itself (the same wrapper on every read,
  // the object must outlive the context); an arithmetic or std::string variable is read live and `self.name = v`
  // writes it back. NAME starts with a lower-case letter or an underscore.
  template <class T>
  Context& bind(const std::string& name, T& obj) {
    using D = std::remove_cv_t<T>;
    if constexpr (detail::is_value_like_v<D>) {
      static_assert(std::is_arithmetic_v<D> || std::is_same_v<D, std::string>,
                    "bind: arithmetic, std::string or a registered class object; use set() for other values");
      T* p = &obj;
      detail::define_global_fn(impl(), name, detail::make_callable<false>([p]() -> D { return *p; }));
      if constexpr (!std::is_const_v<T>)
        detail::define_global_fn(impl(), name + "=", detail::make_callable<false>([p](D v) { *p = std::move(v); }));
    } else {
      static_assert(!std::is_const_v<T>, "bind: a const class object cannot be shared (scripts can call any method)");
      detail::define_global_value(impl(), name, detail::wrap_ref<D>(mrb(), &obj));
    }
    return *this;
  }

  // A script sees `name` as a global holding a copy of VALUE (a class object is moved into a new script-owned object).
  template <class T>
  Context& set(const std::string& name, T&& value) {
    detail::define_global_value(impl(), name, detail::value_of_copy<detail::plain_t<T>>(mrb(), value));
    return *this;
  }

  // A script can call `name(args...)`. F is a function, function pointer, lambda or other callable with one
  // non-template call operator. Parameters: values by copy, registered classes by T&, const T& or T* (the script's
  // object), results likewise (T& and T* are shared, a T is a new script-owned object). Exact arity.
  template <class F>
  Context& bind_fn(const std::string& name, F f) {
    detail::define_global_fn(impl(), name, detail::make_callable<false>(std::move(f)));
    return *this;
  }

  // ---- evaluation ----
  // Runs CODE and returns the value of its last expression. Top-level local variables persist between calls.
  Value eval_value(std::string_view language, std::string_view code);
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

  mrb_state* mrb() const;  // the embedded interpreter, for code that needs the mruby API

 private:
  detail::Impl* impl() const { return p_.get(); }
  std::unique_ptr<detail::Impl> p_;
};

// ---- Value templates -------------------------------------------------------------------------------------------
template <class T>
T Value::as() const {
  if (!impl_) detail::empty_value();
  mrb_state* mrb = detail::state_of(impl_);
  using D = detail::plain_t<T>;
  if constexpr (std::is_pointer_v<D> && !detail::is_cstr_v<D>) {
    return detail::object_ptr<std::remove_pointer_t<D>>(mrb, v_, true);
  } else if constexpr (std::is_lvalue_reference_v<T> && !detail::is_value_like_v<D>) {
    return *detail::object_ptr<D>(mrb, v_, false);
  } else {
    static_assert(!std::is_reference_v<T>, "Value::as<T&>: only for registered classes");
    return detail::from_value<D>(mrb, v_);
  }
}

template <class... A>
Value Value::call(const std::string& name, A&&... args) const {
  if (!impl_) detail::empty_value();
  mrb_state* mrb = detail::state_of(impl_);
  mrb_value argv[sizeof...(A) ? sizeof...(A) : 1];
  std::size_t n = 0;
  ((argv[n++] = detail::to_value<A>(mrb, std::forward<A>(args))), ...);
  return detail::call_method(impl_, v_, name, argv, static_cast<mrb_int>(sizeof...(A)));
}

}  // namespace nfcpoly
