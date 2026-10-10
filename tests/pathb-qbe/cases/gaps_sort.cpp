// EXPECT: 0
// STDOUT: same
// std::sort / stable_sort / partial_sort / nth_element / lower_bound / unique / rotate / partition / accumulate / transform
// with lambdas and function objects over vectors of ints, strings and structs; a deterministic pseudo-random sequence,
// output compared with the gcc backend.
#include <algorithm>
#include <cstdio>
#include <functional>
#include <iterator>
#include <list>
#include <numeric>
#include <string>
#include <vector>

struct Rec {
  int key;
  int seq;
  std::string name;
};

static unsigned long long state = 88172645463325252ULL;
static unsigned next() {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return (unsigned)(state >> 11);
}

template <class C> static void show(const char *label, const C &c) {
  std::printf("%s:", label);
  for (const auto &e : c) std::printf(" %d", (int)e);
  std::printf("\n");
}

int main() {
  std::vector<int> v;
  for (int i = 0; i < 40; i++) v.push_back((int)(next() % 100));
  show("raw", v);
  std::vector<int> a = v;
  std::sort(a.begin(), a.end());
  show("sorted", a);
  std::vector<int> d = v;
  std::sort(d.begin(), d.end(), [](int x, int y) { return x > y; });
  show("desc", d);
  std::vector<int> g = v;
  std::sort(g.begin(), g.end(), std::greater<int>());
  std::printf("greater same as lambda %d\n", (int)(g == d));
  std::vector<int> big;
  for (int i = 0; i < 2000; i++) big.push_back((int)(next() % 1000));
  std::sort(big.begin(), big.end());
  std::printf("big sorted %d first %d last %d\n", (int)std::is_sorted(big.begin(), big.end()), big.front(), big.back());

  // stable_sort keeps the original order of equal keys
  std::vector<Rec> recs;
  for (int i = 0; i < 30; i++) recs.push_back({(int)(next() % 5), i, "r" + std::to_string(i)});
  std::stable_sort(recs.begin(), recs.end(), [](const Rec &x, const Rec &y) { return x.key < y.key; });
  for (const auto &r : recs) std::printf("%d:%d:%s ", r.key, r.seq, r.name.c_str());
  std::printf("\n");
  bool stable = true;
  for (size_t i = 1; i < recs.size(); i++)
    if (recs[i - 1].key == recs[i].key && recs[i - 1].seq > recs[i].seq) stable = false;
  std::printf("stable %d\n", (int)stable);

  std::vector<std::string> words = {"pear", "apple", "fig", "banana", "kiwi", "cherry", "date"};
  std::sort(words.begin(), words.end(), [](const std::string &x, const std::string &y) {
    return x.size() != y.size() ? x.size() < y.size() : x < y;
  });
  for (const auto &w : words) std::printf("%s ", w.c_str());
  std::printf("\n");

  std::vector<int> p = v;
  std::partial_sort(p.begin(), p.begin() + 5, p.end());
  show("partial", std::vector<int>(p.begin(), p.begin() + 5));
  std::vector<int> n = v;
  std::nth_element(n.begin(), n.begin() + 20, n.end());
  std::printf("nth %d vs %d\n", n[20], a[20]);

  auto lb = std::lower_bound(a.begin(), a.end(), 50);
  auto ub = std::upper_bound(a.begin(), a.end(), 50);
  std::printf("bounds %d %d\n", (int)(lb - a.begin()), (int)(ub - a.begin()));
  std::printf("binary_search %d\n", (int)std::binary_search(a.begin(), a.end(), a[7]));

  std::vector<int> u = a;
  u.erase(std::unique(u.begin(), u.end()), u.end());
  show("unique", u);
  std::vector<int> r = {1, 2, 3, 4, 5, 6, 7};
  std::rotate(r.begin(), r.begin() + 3, r.end());
  show("rotate", r);
  auto mid = std::partition(r.begin(), r.end(), [](int x) { return x % 2 == 0; });
  std::printf("partition point %d\n", (int)(mid - r.begin()));
  std::reverse(r.begin(), r.end());
  show("reverse", r);

  std::printf("accumulate %d\n", std::accumulate(v.begin(), v.end(), 0));
  std::printf("product %lld\n", std::accumulate(r.begin(), r.end(), 1LL, std::multiplies<long long>()));
  std::vector<int> sq(v.size());
  std::transform(v.begin(), v.end(), sq.begin(), [](int x) { return x * x; });
  std::printf("transform sum %d\n", std::accumulate(sq.begin(), sq.end(), 0));
  std::vector<int> ps(v.size());
  std::partial_sum(v.begin(), v.end(), ps.begin());
  std::printf("partial_sum back %d\n", ps.back());
  std::printf("count_if %d find_if %d any %d all %d\n", (int)std::count_if(v.begin(), v.end(), [](int x) { return x > 50; }),
              (int)(std::find_if(v.begin(), v.end(), [](int x) { return x > 90; }) - v.begin()),
              (int)std::any_of(v.begin(), v.end(), [](int x) { return x == 0; }),
              (int)std::all_of(v.begin(), v.end(), [](int x) { return x < 100; }));
  auto mm = std::minmax_element(v.begin(), v.end());
  std::printf("minmax %d %d\n", *mm.first, *mm.second);
  std::list<int> l(v.begin(), v.end());
  l.sort();
  l.unique();
  std::printf("list %zu front %d back %d\n", l.size(), l.front(), l.back());
  std::vector<int> merged;
  std::merge(a.begin(), a.begin() + 10, d.begin() + 30, d.end(), std::back_inserter(merged));
  std::sort(merged.begin(), merged.end());
  show("merged", merged);
  std::vector<int> idx(10);
  std::iota(idx.begin(), idx.end(), 100);
  std::next_permutation(idx.begin(), idx.end());
  show("perm", idx);
  return 0;
}
