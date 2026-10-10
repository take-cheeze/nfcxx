// Path B, hosted: <unordered_map> and <unordered_set>. Insertion with rehashing (the rehash policy lives in libstdc++.so and
// returns a std::pair<bool, size_t> in registers: structs by value follow the C calling convention, abi_struct.cpp), find,
// erase, iteration over all elements, string keys, operator[].
// EXPECT: 13
// STDOUT: same
#include <unordered_map>
#include <unordered_set>
#include <string>
#include <cstdio>

int main()
{
  int n = 0;
  std::unordered_set<unsigned long long> s;
  for (unsigned long long i = 0; i < 1000; i++) s.insert(i * 7919);
  n += s.size() == 1000;
  n += s.count(7919 * 500) == 1 && s.count(3) == 0;
  s.erase(7919 * 10);
  n += s.size() == 999 && s.find(7919 * 10) == s.end();
  unsigned long long sum = 0;
  for (auto v : s) sum += v;
  n += sum == 7919ULL * (999 * 1000 / 2 - 10);

  std::unordered_map<int, int> m;
  for (int i = 0; i < 200; i++) m[i] = i * i;
  n += m.size() == 200 && m[13] == 169 && m.at(199) == 199 * 199;
  m[13] += 1;
  n += m[13] == 170;

  std::unordered_map<std::string, int> w;
  w["alpha"] = 1; w["beta"] = 2; w["gamma"] = 3;
  for (int i = 0; i < 100; i++) w["k" + std::to_string(i)] = i;
  n += w.size() == 103 && w["beta"] == 2 && w["k42"] == 42;
  n += w.find("delta") == w.end();
  w.erase("beta");
  n += w.size() == 102 && !w.count("beta");
  n += w.bucket_count() > 100;
  std::printf("n=%d size=%zu\n", n, w.size());
  return n + 3;
}
