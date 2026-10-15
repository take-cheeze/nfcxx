// EXPECT: 0
// <array>: aggregate init, size, element access, iteration, fill, swap, comparison, get<>.
#include <array>

constexpr std::array<int, 4> kTable = {1, 2, 3, 4};
static_assert(kTable.size() == 4);
static_assert(kTable[2] == 3);
static_assert(kTable.front() == 1 && kTable.back() == 4);
static_assert(!kTable.empty());
static_assert(std::array<int, 0>{}.empty());
static_assert(std::get<1>(kTable) == 2);
static_assert(kTable == std::array<int, 4>{1, 2, 3, 4});
static_assert(std::array<int, 2>{1, 2} != std::array<int, 2>{1, 3});
static_assert(std::array<int, 2>{1, 2} < std::array<int, 2>{1, 3});

int main() {
  int fails = 0;
  std::array<int, 5> a = {5, 4, 3, 2, 1};
  fails += a[0] != 5 || a[4] != 1;
  fails += a.size() != 5;
  a.at(1) = 40;
  fails += a.at(1) != 40;

  int total = 0;
  for (int v : a) total += v;
  fails += total != 5 + 40 + 3 + 2 + 1;

  std::array<int, 3> b{};
  b.fill(9);
  fails += b[0] != 9 || b[2] != 9;
  std::array<int, 3> c = {1, 2, 3};
  a.swap(a);
  c.swap(b);
  fails += c[0] != 9 || b[0] != 1;

  std::get<0>(c) = 77;
  fails += std::get<0>(c) != 77;
  fails += *a.data() != 5;
  fails += (a.end() - a.begin()) != 5;

  std::array<char, 0> zero;
  fails += zero.size() != 0 || zero.data() != nullptr || zero.begin() != zero.end();
  return fails;
}
