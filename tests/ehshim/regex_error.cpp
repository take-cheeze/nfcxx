// std::regex_error thrown by <regex> (std::__throw_regex_error) is caught by EDG handlers; valid patterns still match.
// The exit code is the number of wrong results.
// BACKENDS: gcc
// EXPECT: 0
#include <regex>
#include <stdexcept>
#include <string>
#include <cstdio>

static int bad;
#define CHECK(c) do { if (!(c)) { bad++; std::printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main()
{
  try { std::regex r("(unclosed"); CHECK(false); }
  catch (const std::regex_error &e) { CHECK(e.code() == std::regex_constants::error_paren); }
  try { std::regex r("[a"); CHECK(false); }
  catch (const std::regex_error &e) { CHECK(e.code() == std::regex_constants::error_brack); }
  try { std::regex r("a{2,1}"); CHECK(false); }
  catch (const std::runtime_error &) { }
  std::regex ok("a+b");
  CHECK(std::regex_match(std::string("aaab"), ok));
  CHECK(!std::regex_match(std::string("b"), ok));
  std::printf("bad=%d\n", bad);
  return bad;
}
