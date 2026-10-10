// The minimal reproduction: two translation units that both use std::string; main is here.
#include <cstdio>
#include <string>
std::string f();
int main() {
  std::string s = "hi";
  s += f();
  std::puts(s.c_str());
  return s == "hithere!" ? 0 : 1;
}
