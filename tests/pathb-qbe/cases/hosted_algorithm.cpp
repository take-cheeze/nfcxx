// Path B, hosted: <algorithm> with <vector>: sort (with comparator), stable_sort with a lambda, find, count_if,
// reverse, binary_search, unique, transform, min/max, next_permutation.
// EXPECT: 15
// STDOUT: same
#include <algorithm>
#include <vector>
#include <functional>
#include <cstdio>

int main()
{
  int n = 0;
  std::vector<int> v{9, 4, 7, 1, 8, 2, 2, 6};
  std::sort(v.begin(), v.end());
  n += v[0] == 1 && v[7] == 9 && std::is_sorted(v.begin(), v.end());
  std::sort(v.begin(), v.end(), std::greater<int>());
  n += v[0] == 9 && v[7] == 1;
  n += std::find(v.begin(), v.end(), 7) - v.begin() == 1;
  n += std::count_if(v.begin(), v.end(), [](int x) { return x % 2 == 0; }) == 5;
  std::reverse(v.begin(), v.end());
  n += v.front() == 1;
  n += std::binary_search(v.begin(), v.end(), 6);
  v.erase(std::unique(v.begin(), v.end()), v.end());
  n += v.size() == 7;
  n += std::min(3, 4) == 3 && std::max(3, 4) == 4;
  std::vector<int> out(v.size());
  std::transform(v.begin(), v.end(), out.begin(), [](int x) { return x * x; });
  n += out[6] == 81;
  int a[3] = {1, 2, 3}; int perms = 0;
  do { perms++; } while (std::next_permutation(a, a + 3));
  n += perms == 6;
  std::vector<std::pair<int,int>> ps{{2, 1}, {1, 2}, {2, 0}, {1, 1}};
  std::stable_sort(ps.begin(), ps.end(), [](const std::pair<int,int> &x, const std::pair<int,int> &y) { return x.first < y.first; });
  n += ps[0].second == 2 && ps[1].second == 1 && ps[2].second == 1 && ps[3].second == 0;
  std::printf("n=%d\n", n);
  return n + 5;
}
