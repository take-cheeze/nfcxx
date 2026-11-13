// The callers: the calls to the class results of lib.cpp, through a reference, a pointer, an optional and a function pointer.
// EXPECT: 0
#include "class_result.hpp"
#include <cstdio>
static std::string local_cb(int k) { return std::string("cb") + std::to_string(k); }
int main() {
  Impl d; Base* b = &d;
  std::string s = b->who(5);
  std::string m = make(3, "q");
  auto o = maybe(3), n = maybe(0);
  std::string t = through(local_cb, 7);
  Holder h; std::string nm = h.name("ab");
  std::printf("%s|%s|%s|%d|%s|%s\n", s.c_str(), m.c_str(), o ? o->c_str() : "-", (int)n.has_value(), t.c_str(), nm.c_str());
  bool ok = s == "impl:5" && m == "3q" && o && *o == "yes" && !n && t == "cb7" && nm == "ab7";
  return ok ? 0 : 1;
}
