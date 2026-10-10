// TU b: std::map, std::string, the same templates and inline entities as a.cpp.
#include <sstream>
#include <stdexcept>
#include "common.hpp"

int bump_per_tu_b() { return ++per_tu + ++per_tu_anon; }

[[noreturn]] static void fail(const std::string& why) { throw std::runtime_error("b: " + why); }

std::string unit_b(std::map<std::string, int>& m) {
  m["x"] += 1;
  m["y"] += 2;
  m[twice(std::string("z"))] += 3;
  shared_total += 5;
  int id2 = next_id();
  Stats<int> s1, s2;  // Stats<int>::created / count are shared with a.cpp
  s1.add(1); s2.add(2);
  std::ostringstream os;
  for (auto& kv : m) os << kv.first << "=" << kv.second << " ";
  os << "id=" << id2 << " total=" << shared_total << " created=" << Stats<int>::created << " count=" << Stats<int>::count
     << " tw=" << twice(2.5);
  int bumped = bump_per_tu_b();  // a separate statement: the front end does not order the operands of a << chain
  os << " per_tu=" << bumped << " per_tu_here=" << per_tu;
  Rect r(4, 6);
  const Shape& sh = r;
  os << " " << sh.name() << sh.area();
  try { fail("boom"); } catch (const std::exception& e) { os << " caught(" << e.what() << ")"; }
  return os.str();
}
