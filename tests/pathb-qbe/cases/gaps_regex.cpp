// EXPECT: 0
// STDOUT: same
// std::regex (search, match, replace, iterators over matches); the heaviest header set tried on Path B. Output compared with gcc.
#include <regex>
#include <string>
#include <cstdio>
int main() {
  std::regex re("([a-z]+)@([a-z]+)\\.com");
  std::smatch m;
  std::string s = "mail bob@example.com and alice@site.com now";
  int n = 0;
  std::string::const_iterator it = s.cbegin();
  while (std::regex_search(it, s.cend(), m, re)) {
    std::printf("%s | %s | %s\n", m[0].str().c_str(), m[1].str().c_str(), m[2].str().c_str());
    it = m.suffix().first;
    n++;
  }
  std::printf("n=%d match=%d\n", n, (int)std::regex_match("abc123", std::regex("[a-z]+[0-9]+")));
  std::printf("%s\n", std::regex_replace("a-b-c", std::regex("-"), "+").c_str());
  return 0;
}
