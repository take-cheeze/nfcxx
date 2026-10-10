// long double through libstdc++'s I/O (docs/notes/pathb-longdouble.md): ostream::operator<<(long double) and
// istream::operator>>(long double&) (they call _M_insert<long double> / _M_extract<long double> in libstdc++.so with the
// argument in memory), std::stold, to_chars, from_chars, stringstream, printf and scanf families, locale formatting.
// EXPECT: 0
// STDOUT: same
#include <iostream>
#include <sstream>
#include <iomanip>
#include <string>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <limits>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main() {
  long double x = 1.0L / 7;
  std::cout << std::setprecision(20) << x << "\n";
  std::cout << std::setprecision(6) << 123456.789L << " " << 1e-5L << " " << 1e4000L << " " << -0.0L << "\n";
  std::cout << std::fixed << std::setprecision(3) << 2.0L / 3 << " " << std::scientific << 12345.678L << " "
            << std::hexfloat << 1.5L << "\n";
  std::cout << std::defaultfloat << std::showpos << 2.5L << " " << std::noshowpos << std::setw(12) << std::left << 3.5L << "|"
            << std::setw(12) << std::right << std::setfill('*') << 4.5L << "\n";
  std::cout << std::numeric_limits<long double>::infinity() << " " << -std::numeric_limits<long double>::infinity() << " "
            << std::numeric_limits<long double>::quiet_NaN() << "\n";

  std::ostringstream os; os << std::setprecision(25) << std::fixed << 1.0L / 3;
  CHECK(os.str() == "0.3333333333333333333423684");   // the exact value of the 64-bit mantissa
  std::cout << os.str() << "\n";

  long double a = 0, b = 0, c = 0;
  std::istringstream is("3.75 -2.5e3 1.5e0 junk");
  is >> a >> b >> c;
  CHECK(a == 3.75L && b == -2500.0L && c == 1.5L && is.good());
  std::string w; is >> w; CHECK(w == "junk");
  std::istringstream bad("abc"); long double d = 7; bad >> d;
  CHECK(bad.fail());

  CHECK(std::to_string(1.5L) == "1.500000" && std::to_string(-2.5e10L) == "-25000000000.000000" && std::to_string(0.1L) == "0.100000");
  CHECK(std::stold("2.718281828459045235360287") == 2.718281828459045235360287L);
  CHECK(std::stold("  -1e-4000") < 0 && std::stold("1e-4000") > 0 && std::stold("0x10") == 16.0L);
  size_t pos; long double sv = std::stold("1.5abc", &pos);
  CHECK(sv == 1.5L && pos == 3);

  char buf[64];
  auto r = std::to_chars(buf, buf + sizeof buf, 0.1L);
  CHECK(std::string(buf, r.ptr) == "0.1");
  r = std::to_chars(buf, buf + sizeof buf, 1e20L, std::chars_format::scientific);
  CHECK(std::string(buf, r.ptr) == "1e+20");
  r = std::to_chars(buf, buf + sizeof buf, 1.0L / 3, std::chars_format::fixed, 10);
  CHECK(std::string(buf, r.ptr) == "0.3333333333");
  long double fv = 0; const char* in = "6.02214076e23xyz";
  auto fr = std::from_chars(in, in + 16, fv);
  CHECK(fr.ec == std::errc() && *fr.ptr == 'x' && fv == 6.02214076e23L);
  printf("%La\n", fv);

  snprintf(buf, sizeof buf, "%10.3Lf|%-12.2Le|%Lg|%La", 3.14159265L, 12345.6789L, 1e-7L, 0.1L);
  CHECK(std::string(buf) == "     3.142|1.23e+04    |1e-07|0xc.ccccccccccccccdp-7");
  long double sc1 = 0, sc2 = 0;
  int got = sscanf("2.5 7.25e2", "%Lf %Lg", &sc1, &sc2);
  CHECK(got == 2 && sc1 == 2.5L && sc2 == 725.0L);
  wchar_t wb[32]; swprintf(wb, 32, L"%.4Lf", 1.0L / 3);
  CHECK(std::wstring(wb) == L"0.3333");
  printf("%s\n", buf);
  printf("%d\n", fails);
  return fails;
}
