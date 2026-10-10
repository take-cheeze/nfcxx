// std::format and std::to_chars with _Float128 (docs/notes/pathb-float128.md): GCC 13's <format> instantiates its
// visitor for _Float128 whatever the arguments are, and formats a __float128 through to_chars(char*, char*, _Float128)
// of libstdc++.so, which takes the value in an SSE register (the wrapper __nfcxx_f128w_ does that). The probes print
// what the gcc backend prints.
// STDOUT: same
// EXPECT: 0
#include <charconv>
#include <cstdio>
#include <format>
#include <string>

int main() {
  // the probe of the task: a long double and an int
  std::string s = std::format("{} {}", 1.5L, 2);
  std::printf("%s\n", s.c_str());
  std::printf("%s\n", std::format("{:.3f} {:e} {:g}", 2.0, 1234.5, 0.25).c_str());
  std::printf("%s\n", std::format("{} {:>8.2Lf}", 3.5L, 2.0L / 3).c_str());

  // __int128 and unsigned __int128 (formatted through their own visitor entries)
  __int128 a = -((__int128)1 << 100) + 7;
  unsigned __int128 b = ((unsigned __int128)1 << 70) + 3;
  std::printf("%s\n", std::format("{} {}", a, b).c_str());

  // _Float128: to_chars (the wrappers) and format, with and without a format specification
  __float128 q = 1.5;
  char buf[64];
  std::to_chars_result r = std::to_chars(buf, buf + sizeof buf, q);
  *r.ptr = '\0';
  std::printf("%s\n", buf);
  std::printf("%s\n", std::format("{} {}", q, (__float128)-0.25).c_str());
  r = std::to_chars(buf, buf + sizeof buf, (__float128)1.0 / 8, std::chars_format::scientific);
  *r.ptr = '\0';
  std::printf("%s\n", buf);
  r = std::to_chars(buf, buf + sizeof buf, (__float128)100.0, std::chars_format::fixed, 3);
  *r.ptr = '\0';
  std::printf("%s\n", buf);
  return s == "1.5 2" ? 0 : 1;
}
