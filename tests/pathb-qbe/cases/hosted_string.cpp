// Path B, hosted: <string>. Construction, append, operator+, compare, find, substr, c_str, push_back, insert/erase,
// long strings (heap), move, std::to_string, iteration.
// EXPECT: 22
// STDOUT: same
#include <string>
#include <cstdio>

int main()
{
  int n = 0;
  std::string a = "hello";
  std::string b(" world");
  std::string c = a + b;
  n += c == "hello world";
  n += c.size() == 11;
  c.push_back('!');
  n += c.back() == '!';
  n += c.find("wor") == 6;
  n += c.substr(6, 5) == "world";
  n += c.compare("hello") > 0;
  std::string big(100, 'x');
  big += "tail";
  n += big.size() == 104 && big[103] == 'l';
  std::string d = std::move(big);
  n += d.size() == 104 && big.empty();
  d.erase(0, 100);
  n += d == "tail";
  d.insert(2, "--");
  n += d == "ta--il";
  std::string e = std::to_string(12345) + std::to_string(-7);
  n += e == "12345-7";
  int cnt = 0;
  for (char ch : c) cnt += ch == 'o';
  n += cnt == 2;
  n += std::string("abc") < std::string("abd");
  std::printf("%s|%s|%zu\n", c.c_str(), e.c_str(), d.size());
  std::string r;
  for (int i = 0; i < 50; i++) r += char('a' + i % 26);
  n += r.size() == 50 && r[27] == 'b';
  n += r.rfind('a') == 26;
  return n + 7;
}
