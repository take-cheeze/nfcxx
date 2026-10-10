// Shared by the translation units of tests/multi-tu. Everything here is something C++ lets every TU define
// (and requires the link to merge): inline functions, templates, inline variables, static data members of
// templates, local statics of inline functions, vtables and typeinfo of classes with inline members, plus a
// class template that is declared `extern template` and explicitly instantiated in exactly one TU.
#pragma once
#include <map>
#include <string>
#include <vector>

// inline function with a local static: one counter for the whole program
inline int next_id() {
  static int counter = 100;
  return ++counter;
}

// inline variable: one object for the whole program
inline int shared_total = 0;
inline const std::string greeting = "hello";

template <class T>
struct Stats {
  static inline int created = 0;  // static data member of a template (inline)
  static int count;               // static data member of a template (defined out of class)
  T sum{};
  Stats() { ++created; ++count; }
  void add(T v) { sum += v; }
};
template <class T>
int Stats<T>::count = 0;

template <class T>
T twice(T v) { return v + v; }

template <class T>
inline constexpr T pi_like = T(3);  // variable template

// a polymorphic class: vtable and typeinfo are emitted where the key function is, or in every TU
struct Shape {
  virtual ~Shape() {}
  virtual int area() const = 0;
  virtual std::string name() const { return "shape"; }
};
struct Square : Shape {
  int s;
  explicit Square(int s) : s(s) {}
  int area() const override { return s * s; }
  std::string name() const override { return "square"; }
};
struct Rect : Shape {
  int w, h;
  Rect(int w, int h) : w(w), h(h) {}
  int area() const override { return w * h; }
};

// extern template: the definition of every member is emitted by the one TU that instantiates it (c.cpp)
template <class T>
struct Box {
  T v;
  explicit Box(T v) : v(v) {}
  T get() const;
  T plus(T o) const { return v + o; }
};
template <class T>
T Box<T>::get() const { return v; }
extern template struct Box<long>;

// ordinary (non-inline) functions and objects: defined in exactly one TU, used by the others
int program_wide_counter_bump();
extern int program_wide_value;

// internal linkage: every TU has its own copy
static int per_tu = 0;
namespace { int per_tu_anon = 0; }
int bump_per_tu_a();
int bump_per_tu_b();

// the TUs report through these (defined in main.cpp)
std::string unit_a(std::vector<std::string>& v);
std::string unit_b(std::map<std::string, int>& m);
std::string unit_c();
