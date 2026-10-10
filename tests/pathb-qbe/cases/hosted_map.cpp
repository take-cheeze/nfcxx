// Path B, hosted: <map>. std::map<int,int> and <string,int>: insert, operator[], find, erase, ordered iteration,
// count, lower_bound, std::set.
// EXPECT: 15
// STDOUT: same
#include <map>
#include <set>
#include <string>
#include <cstdio>

int main()
{
  int n = 0;
  std::map<int, int> m;
  for (int i = 0; i < 50; i++) m[(i * 7) % 50] = i;
  n += m.size() == 50;
  n += m[0] == 0 && m[7] == 1;
  int prev = -1; bool ordered = true;
  for (auto &kv : m) { ordered = ordered && kv.first > prev; prev = kv.first; }
  n += ordered;
  n += m.find(13) != m.end() && m.find(100) == m.end();
  m.erase(13);
  n += m.count(13) == 0 && m.size() == 49;
  n += m.lower_bound(13)->first == 14;
  std::map<std::string, int> w;
  w["apple"] = 1; w["pear"] = 2; w["fig"] = 3; w["apple"] += 10;
  n += w["apple"] == 11 && w.size() == 3;
  std::string order;
  for (auto &kv : w) order += kv.first[0];
  n += order == "afp";
  std::map<int, std::string> r;
  r.insert({2, "b"}); r.insert({1, "a"}); r.insert({2, "zz"});
  n += r.size() == 2 && r[2] == "b";
  std::set<int> s{5, 1, 3, 1, 5};
  n += s.size() == 3 && *s.begin() == 1;
  std::printf("n=%d\n", n);
  return n + 5;
}
