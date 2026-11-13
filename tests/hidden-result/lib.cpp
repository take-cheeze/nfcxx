// The definitions of the class results of class_result.hpp. Each returns a string whose short-string buffer is inside the object,
// so a result copied after the call would point into a dead frame.
#include "class_result.hpp"
#include <cstdio>
std::string Impl::who(int k) const { return std::string("impl:") + std::to_string(k); }
std::string make(int a, std::string_view k) { return std::to_string(a) + std::string(k); }
std::optional<std::string> maybe(int k) { if (k > 0) return std::string("yes"); return std::nullopt; }
std::string through(std::string (*f)(int), int k) { return f(k); }
std::string Holder::name(std::string_view k) const { return std::string(k) + std::to_string(tag); }
