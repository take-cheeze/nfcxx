// Several nfcxx-compiled translation units that all use std::string and friends, linked into one program.
// Run by tests/multi-tu/run.sh (one command with all files, and separate objects linked later).
#include <cstdio>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
#include "common.hpp"

static int failures = 0;
static void check(const char* what, const std::string& got, const std::string& want) {
  if (got == want) return;
  std::printf("FAIL %s:\n  got  %s\n  want %s\n", what, got.c_str(), want.c_str());
  failures++;
}

int main() {
  std::vector<std::string> v;
  std::map<std::string, int> m;
  std::string a = unit_a(v);
  // a.cpp: sorted strings, shapes (3*3 + 2*5 = 19), Stats sum 42, id 101, pi_like 3 + 3, per-TU counters 1 + 1
  check("unit_a", a, "a1;abab;hello;square,shape,19:42:101:6:2");
  std::string b = unit_b(m);
  // b.cpp: the second next_id() is 102, shared_total is 15, two Stats<int> were made in b and one in a
  check("unit_b", b,
        "x=1 y=2 zz=3 id=102 total=15 created=3 count=3 tw=5 per_tu=2 per_tu_here=1 shape24 caught(b: boom)");
  // main.cpp's own copy of the internal-linkage variables is untouched by the other TUs
  check("per-TU copies", std::to_string(per_tu) + std::to_string(per_tu_anon), "00");
  int c1 = program_wide_counter_bump();
  int c2 = program_wide_counter_bump();
  check("program-wide", std::to_string(c1) + std::to_string(c2) + std::to_string(program_wide_value), "1242");
  check("inline entities", std::to_string(next_id()) + ":" + std::to_string(shared_total) + ":" + greeting,
        "103:15:hello");
  try {
    unit_c();
    check("exception across TUs", "no exception", "std::logic_error");
  } catch (const std::logic_error& e) {
    check("exception across TUs", e.what(), "c: 15sst");
  }
  if (failures) return 1;
  std::puts("all checks passed");
  return 0;
}
