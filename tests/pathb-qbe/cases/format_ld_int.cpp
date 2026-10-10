// The probe of the float128 work (docs/notes/pathb-float128.md): std::format("{} {}", 1.5L, 2) builds and prints what gcc
// prints. The formatter instantiates its visitor for every argument type, _Float128 included.
// STDOUT: same
// EXPECT: 0
#include <format>
#include <cstdio>
#include <string>

int main() {
  std::string s = std::format("{} {}", 1.5L, 2);
  std::printf("%s\n", s.c_str());
  return s == "1.5 2" ? 0 : 1;
}
