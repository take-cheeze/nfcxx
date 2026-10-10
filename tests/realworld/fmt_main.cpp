// {fmt} real-world driver (header-only mode, FMT_HEADER_ONLY): width/precision/alignment/fill, integer bases,
// floating point, named arguments, positional arguments, fmt::format_to into a memory buffer, fmt::print to
// stdout, a user-defined formatter, a range/tuple formatter, compile-time checked format strings, and format
// errors. Single translation unit; the whole output is compared with the host g++ build.
// With -DFMT_COMPILED_UNITY the library is not header-only: src/format.cc and src/os.cc are included at the end of
// this file, so the compiled library is built from the same single translation unit.
#ifndef FMT_COMPILED_UNITY
#define FMT_HEADER_ONLY 1
#endif
#include <fmt/format.h>
#ifdef FMT_COMPILED_UNITY
#include <fmt/os.h>
#endif
#include <fmt/compile.h>
#include <fmt/ranges.h>
#include <cstdio>
#include <cstdlib>
#include <system_error>
#include <unistd.h>
#include <limits>
#include <map>
#include <string>
#include <vector>

struct Point {
  double x, y;
};
template <> struct fmt::formatter<Point> {
  char presentation = 'f';
  constexpr auto parse(format_parse_context &ctx) -> format_parse_context::iterator {
    auto it = ctx.begin(), end = ctx.end();
    if (it != end && (*it == 'f' || *it == 'e')) presentation = *it++;
    if (it != end && *it != '}') report_error("invalid Point format");
    return it;
  }
  auto format(const Point &p, format_context &ctx) const -> format_context::iterator {
    return presentation == 'f' ? fmt::format_to(ctx.out(), "({:.1f}, {:.1f})", p.x, p.y)
                               : fmt::format_to(ctx.out(), "({:.2e}, {:.2e})", p.x, p.y);
  }
};

enum class Color { red, green, blue };
static const char *name(Color c) { return c == Color::red ? "red" : c == Color::green ? "green" : "blue"; }
template <> struct fmt::formatter<Color> : fmt::formatter<std::string> {
  auto format(Color c, format_context &ctx) const { return fmt::formatter<std::string>::format(name(c), ctx); }
};

int main() {
  // basics
  std::string s = fmt::format("{} {} {}", 1, 2.5, "three");
  std::puts(s.c_str());
  std::puts(fmt::format("[{:>8}] [{:<8}] [{:^8}] [{:*^9}] [{:08.3f}] [{:+}] [{:#x}] [{:#b}] [{:o}]", "right", "left",
                        "mid", "fill", 3.14159265, 42, 255, 5, 64)
                .c_str());
  std::puts(fmt::format("{0} {1} {0} {2:.3}", "a", "b", 1.0 / 3).c_str());
  std::puts(fmt::format("{:10.4f}|{:<10d}|{:^10s}|{:>10}", 2.718281828, 42, "ab", true).c_str());
  std::puts(fmt::format("{:e} {:g} {:g} {:a} {}", 12345.6789, 1e-5, 1e10, 1.0, 1e21).c_str());
  std::puts(fmt::format("{} {} {} {}", 0.1, 100.0, 1.5e-7, -0.0).c_str());
  std::puts(fmt::format("{} {} {}", 1e300 * 1e10, -1e300 * 1e10, std::numeric_limits<double>::quiet_NaN()).c_str());
  std::puts(fmt::format("{:d} {:d} {:x} {:X} {:c}", -5, 123456789012345LL, 3735928559u, 48879, 'Q').c_str());
  std::puts(fmt::format("{} {}", 18446744073709551615ULL, -9223372036854775807LL - 1).c_str());
  std::puts(fmt::format("{:{}} {:.{}f}", 7, 5, 3.14159, 2).c_str());
  std::puts(fmt::format("{:L} {}", 1234567, static_cast<void *>(nullptr)).c_str());
  std::puts(fmt::format("{{literal}} {}", fmt::format("{:?}", std::string("q\"\n\t"))).c_str());

  // named arguments
  std::puts(fmt::format("{name} is {age} years, {name}!", fmt::arg("name", "Ada"), fmt::arg("age", 36)).c_str());
  using namespace fmt::literals;
  std::puts(fmt::format("{x}+{y}={z:.1f}", "x"_a = 1, "y"_a = 2, "z"_a = 3.0).c_str());

  // format_to into a buffer
  char buf[64];
  auto r = fmt::format_to_n(buf, sizeof buf - 1, "{}-{:03}-{}", "id", 7, 'z');
  *r.out = 0;
  std::printf("format_to_n: %s (%zu)\n", buf, r.size);
  fmt::memory_buffer mb;
  fmt::format_to(std::back_inserter(mb), "{}{}{}", 1, 22, 333);
  fmt::format_to(std::back_inserter(mb), " {:>5}", "x");
  std::printf("memory_buffer: %.*s size=%zu\n", static_cast<int>(mb.size()), mb.data(), mb.size());
  std::string out;
  fmt::format_to(std::back_inserter(out), "{:>6.2f}|", 3.14159);
  fmt::format_to(std::back_inserter(out), "{}", std::string(3, '#'));
  std::puts(out.c_str());
  std::printf("formatted_size: %zu\n", fmt::formatted_size("{:>10}", "abc"));

  // print to stdout
  fmt::print("print: {} {:>4} {:.2f}\n", "hello", 12, 2.0 / 3);
  fmt::print(stdout, "to file: {}\n", 99);
  std::fflush(stdout);

  // user-defined formatters
  Point p{1.25, -3.5};
  std::puts(fmt::format("{} {:e} {:f}", p, p, p).c_str());
  std::puts(fmt::format("{} {:>8} {:<8}|", Color::green, Color::red, Color::blue).c_str());

  // ranges, tuples, containers
  std::vector<int> v{1, 2, 3};
  std::map<std::string, int> m{{"a", 1}, {"b", 2}};
  std::puts(fmt::format("{} {} {}", v, m, std::make_tuple(1, "two", 3.0)).c_str());
  std::puts(fmt::format("{}", fmt::join(v, ", ")).c_str());
  std::puts(fmt::format("{:n}", v).c_str());

  // compile-time checked format strings (C++20 consteval format_string, or FMT_STRING)
  std::puts(fmt::format(FMT_STRING("{:>5}|{:<5}|"), 1, 2).c_str());
  std::puts(fmt::format(FMT_STRING("{}"), Point{0, 1}).c_str());
  constexpr auto ct = FMT_COMPILE("{}-{}");
  (void)ct;

  // errors at run time
  const char *bad[] = {"{", "{:d}", "{} {}", "{:z}", "{0} {}", "{name}", "}"};
  for (const char *f : bad) {
    try {
      std::string arg = "str";
      std::string t = fmt::vformat(f, fmt::make_format_args(arg));
      std::printf("no error for '%s': %s\n", f, t.c_str());
    } catch (const fmt::format_error &e) {
      std::printf("format_error for '%s': %s\n", f, e.what());
    }
  }
#ifdef FMT_COMPILED_UNITY
  // fmt/os.h (src/os.cc): buffered output file, read back with stdio
  const char *tmpdir = std::getenv("TMPDIR");
  std::string path = std::string(tmpdir ? tmpdir : "/tmp") + "/nfcxx_fmt_os_" + std::to_string(::getpid()) + ".txt";
  {
    auto f = fmt::output_file(path.c_str());
    f.print("line {} {:>4}\n", 1, "two");
    f.print("pi={:.4f}\n", 3.14159265);
  }
  if (FILE *in = std::fopen(path.c_str(), "r")) {
    char line[128];
    while (std::fgets(line, sizeof line, in)) std::printf("file: %s", line);
    std::fclose(in);
  }
  std::remove(path.c_str());
  try {
    fmt::output_file("/nonexistent-dir/x");
  } catch (const std::system_error &e) {
    std::printf("system_error: code=%d\n", e.code().value());
  }
#endif
  return 0;
}

#ifdef FMT_COMPILED_UNITY
#include <format.cc>
#include <os.cc>
#endif
