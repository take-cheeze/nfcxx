// Prints what std::locale and std::ctype<char> report for every byte value, so the output of a cross-built binary can be
// compared with the output of the same source built by the Mac's own clang++. No expected values are written here.
#include <cstdio>
#include <locale>
#include <string>

int main() {
  std::locale classic = std::locale::classic();
  std::printf("name=%s\n", classic.name().c_str());
  std::printf("global-is-classic=%d\n", std::locale() == classic);

  const std::ctype<char>& ct = std::use_facet<std::ctype<char>>(classic);
  for (int c = 0; c < 256; ++c) {
    char ch = static_cast<char>(c);
    std::printf("%3d alpha=%d digit=%d space=%d upper=%d lower=%d punct=%d print=%d cntrl=%d xdigit=%d up=%d low=%d\n",
                c, ct.is(std::ctype_base::alpha, ch), ct.is(std::ctype_base::digit, ch),
                ct.is(std::ctype_base::space, ch), ct.is(std::ctype_base::upper, ch),
                ct.is(std::ctype_base::lower, ch), ct.is(std::ctype_base::punct, ch),
                ct.is(std::ctype_base::print, ch), ct.is(std::ctype_base::cntrl, ch),
                ct.is(std::ctype_base::xdigit, ch), static_cast<unsigned char>(ct.toupper(ch)),
                static_cast<unsigned char>(ct.tolower(ch)));
  }

  std::string s = "Hello, World! 0123 xyz";
  std::string up = s, low = s;
  ct.toupper(&up[0], &up[0] + up.size());
  ct.tolower(&low[0], &low[0] + low.size());
  std::printf("upper=%s\nlower=%s\n", up.c_str(), low.c_str());
  std::printf("widen-a=%d narrow-A=%d\n", static_cast<int>(ct.widen('a')), static_cast<int>(ct.narrow('A', '?')));

  const std::numpunct<char>& np = std::use_facet<std::numpunct<char>>(classic);
  std::printf("decimal-point=%c thousands-sep=%d grouping-size=%d truename=%s falsename=%s\n", np.decimal_point(),
              static_cast<int>(np.thousands_sep()), static_cast<int>(np.grouping().size()),
              np.truename().c_str(), np.falsename().c_str());

  std::printf("ok\n");
  return 0;
}
