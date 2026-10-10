// Path B, hosted: <vector>. push_back growth, indexing, iterators, insert/erase, resize, copy/move, vector of
// objects with constructors/destructors (live count), vector<bool>. (at() throwing out_of_range is left out: the exception comes from
// libstdc++.so, whose unwinder EDG's setjmp/longjmp exception ABI cannot catch, on both paths; docs/notes/pathb-hosted.md.)
// EXPECT: 12
// STDOUT: same
#include <vector>
#include <stdexcept>
#include <cstdio>

static int live;
struct O { int v; O(int x = 0) : v(x) { live++; } O(const O &o) : v(o.v) { live++; } ~O() { live--; } };

int main()
{
  int n = 0;
  std::vector<int> v;
  for (int i = 0; i < 100; i++) v.push_back(i * 2);
  n += v.size() == 100 && v[99] == 198;
  long s = 0;
  for (std::vector<int>::iterator it = v.begin(); it != v.end(); ++it) s += *it;
  n += s == 9900;
  v.erase(v.begin(), v.begin() + 90);
  n += v.size() == 10 && v[0] == 180;
  v.insert(v.begin() + 1, 7);
  n += v[1] == 7 && v.size() == 11;
  v.resize(3);
  n += v.size() == 3;
  std::vector<int> w = v;
  n += w == v;
  std::vector<int> m = std::move(w);
  n += m.size() == 3 && w.empty();
  {
    std::vector<O> os;
    for (int i = 0; i < 20; i++) os.emplace_back(i);
    n += live == 20 && os[19].v == 19;
    os.pop_back();
    n += live == 19;
  }
  n += live == 0;
  std::vector<bool> bs(70, false);
  bs[65] = true;
  n += bs[65] && !bs[64];
  std::vector<std::vector<int>> g(3, std::vector<int>(4, 1));
  g[2][3] = 5;
  n += g[2][3] == 5 && g[1][1] == 1;
  std::printf("n=%d\n", n);
  return n;
}
