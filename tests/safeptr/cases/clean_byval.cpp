// Iterators and an empty comparator passed by value (std::sort): QBE keeps such a parameter in storage of its own, with
// no padding byte after it, and the next byte may be another parameter's. A pointer to one is found as that object, not
// as one past the end of its neighbour (a false out-of-bounds access before the runtime knew which storage is unpadded).
// EXPECT: 0
#include <algorithm>
#include <functional>
#include <vector>
struct Less { bool operator()(int a, int b) const { return a < b; } };
struct Pair { int k; long v; };
static long fold(std::vector<Pair>::iterator b, std::vector<Pair>::iterator e, Pair init) {
  for (; b != e; ++b) init.v += b->v * b->k;
  return init.v;
}
int main() {
  std::vector<int> v;
  for (int i = 0; i < 5000; i++) v.push_back((i * 7919) % 5003);
  std::sort(v.begin(), v.end());
  if (!std::is_sorted(v.begin(), v.end())) return 1;
  std::sort(v.begin(), v.end(), Less());
  std::sort(v.begin(), v.end(), std::greater<int>());
  if (v.front() < v.back()) return 2;
  std::vector<Pair> ps;
  for (int i = 0; i < 100; i++) ps.push_back(Pair{i, 2});
  if (fold(ps.begin(), ps.end(), Pair{0, 1}) != 1 + 2 * 4950) return 3;
  return 0;
}
