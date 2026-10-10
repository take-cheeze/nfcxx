// EXPECT: 0
// STDOUT: same
// Containers (deque, list, map, multimap, set, unordered_*), bitset, string_view, span, any, <bit>, <random> engines and integer
// distributions, shuffle; an aggregate with a repeated initializer ({} of an array member, ck_init_repeat). Output compared with gcc.
// (std::uniform_real_distribution and normal_distribution use long double inside libstdc++ headers: refused, see pathb-hosted.md.)
#include <any>
#include <bitset>
#include <bit>
#include <cstdio>
#include <deque>
#include <list>
#include <map>
#include <set>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <random>
#include <numeric>
#include <algorithm>

int main() {
  std::deque<int> dq;
  for (int i = 0; i < 20; i++) { if (i % 2) dq.push_back(i); else dq.push_front(i); }
  std::printf("deque %zu %d %d\n", dq.size(), dq.front(), dq.back());
  std::list<std::string> ls = {"x", "yy", "zzz"};
  ls.push_front("w");
  ls.remove("yy");
  for (auto &s : ls) std::printf("%s ", s.c_str());
  std::printf("\n");
  std::map<std::string, int> mp;
  for (const char *w : {"one", "two", "three", "two", "one", "one"}) mp[w]++;
  for (auto &kv : mp) std::printf("%s=%d ", kv.first.c_str(), kv.second);
  std::printf("\n");
  std::multimap<int, char> mm = {{1, 'a'}, {2, 'b'}, {1, 'c'}};
  std::printf("multimap %zu %zu\n", mm.count(1), mm.size());
  std::set<int> st = {5, 3, 9, 1};
  st.insert(4);
  std::printf("set %d %d %zu\n", *st.begin(), *st.rbegin(), st.count(9));
  std::unordered_map<std::string, std::vector<int>> um;
  for (int i = 0; i < 100; i++) um["k" + std::to_string(i % 7)].push_back(i);
  std::printf("umap %zu %zu\n", um.size(), um["k3"].size());
  std::unordered_set<long> us;
  for (long i = 0; i < 1000; i++) us.insert(i * i % 97);
  std::printf("uset %zu\n", us.size());
  std::bitset<70> bs;
  bs.set(3); bs.set(69); bs.flip(4);
  std::printf("bitset %zu %s\n", bs.count(), bs.to_string().substr(0, 8).c_str());
  std::string_view sv = "hello world";
  std::printf("sv %zu %.*s %d\n", sv.find("world"), (int)sv.substr(0, 5).size(), sv.data(), (int)sv.starts_with("hell"));
  std::vector<int> v = {1, 2, 3, 4, 5, 6};
  std::span<int> sp(v);
  std::printf("span %zu %d\n", sp.subspan(2, 3).size(), sp.last(2)[0]);
  std::any a = 42;
  std::printf("any %d %d\n", std::any_cast<int>(a), (int)a.has_value());
  a = std::string("str");
  std::printf("any %s\n", std::any_cast<std::string>(a).c_str());
  std::printf("bit %d %d %d %u %d\n", std::popcount(0xf0f0u), std::countl_zero(1u), std::countr_zero(8u), std::byteswap(0x01020304u), (int)std::has_single_bit(64u));
  std::printf("bitfloor %u %u rotl %u\n", std::bit_floor(100u), std::bit_ceil(100u), std::rotl(0x80000001u, 1));
  std::mt19937 gen(12345);
  std::uniform_int_distribution<int> d(1, 6);
  int sum = 0;
  for (int i = 0; i < 1000; i++) sum += d(gen);
  std::printf("mt %d %u\n", sum, gen());
  std::mt19937_64 g64(1);
  std::printf("mt64 %llu\n", (unsigned long long)g64());
  std::vector<int> sh(10);
  std::iota(sh.begin(), sh.end(), 0);
  std::shuffle(sh.begin(), sh.end(), gen);
  for (int x : sh) std::printf("%d ", x);
  std::printf("\n");
  return 0;
}
