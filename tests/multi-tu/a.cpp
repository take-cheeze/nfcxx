// TU a: std::string, std::vector, templates, inline functions and variables, polymorphic classes.
#include <algorithm>
#include <memory>
#include "common.hpp"

int program_wide_counter_bump() {
  static int n = 0;  // a plain (non-inline) function's local static: one per program as well
  return ++n;
}

int bump_per_tu_a() { return ++per_tu + ++per_tu_anon; }  // this TU's own copies

std::string unit_a(std::vector<std::string>& v) {
  v.push_back("a1");
  v.push_back(twice(std::string("ab")));
  v.push_back(greeting);
  shared_total += 10;
  int id1 = next_id();  // 101 or later: shared with b.cpp
  Stats<int> s;
  s.add(twice(21));
  std::unique_ptr<Shape> shapes[2] = {std::make_unique<Square>(3), std::make_unique<Rect>(2, 5)};
  int area = 0;
  std::string names;
  for (auto& p : shapes) { area += p->area(); names += p->name() + ","; }
  std::sort(v.begin(), v.end());
  std::string out;
  for (auto& e : v) out += e + ";";
  return out + names + std::to_string(area) + ":" + std::to_string(s.sum) + ":" + std::to_string(id1) + ":" +
         std::to_string(pi_like<int> + (int)pi_like<long>) + ":" + std::to_string(bump_per_tu_a());
}
