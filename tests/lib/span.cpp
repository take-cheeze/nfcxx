// EXPECT: 0
// <span>: construction from arrays and std::array, const conversion, first/last/subspan, bounds.
#include <array>
#include <span>

static_assert(std::span<int>().size() == 0);
static_assert(std::span<int>().empty());
static_assert(std::span<int>::extent == std::dynamic_extent);

constexpr int kArr[4] = {10, 20, 30, 40};
static_assert(std::span<const int>(kArr).size() == 4);
static_assert(std::span<const int>(kArr)[3] == 40);
static_assert(std::span<const int>(kArr).subspan(1, 2)[0] == 20);

int total(std::span<const int> s) {
  int t = 0;
  for (int v : s) t += v;
  return t;
}

int main() {
  int fails = 0;
  int arr[5] = {1, 2, 3, 4, 5};
  std::span<int> all(arr);
  fails += all.size() != 5;
  fails += all.size_bytes() != 5 * sizeof(int);
  all[0] = 100;
  fails += arr[0] != 100;

  fails += total(arr) != 100 + 2 + 3 + 4 + 5;     // int[5] -> span<const int>
  fails += total(all.first(2)) != 102;
  fails += total(all.last(2)) != 9;
  fails += total(all.subspan(1)) != 14;
  fails += total(all.subspan(1, 3)) != 9;
  fails += all.subspan(5).size() != 0;              // offset == size is allowed
  fails += all.first(0).data() != arr;

  std::array<int, 3> sa = {7, 8, 9};
  std::span<int> fromArray(sa);
  fromArray[1] = 80;
  fails += sa[1] != 80;
  std::span<const int> cview(sa);
  fails += cview[2] != 9;

  std::span<int> none;
  fails += none.data() != nullptr;

  // span<int> converts to span<const int>.
  std::span<const int> cs = all;
  fails += cs.size() != 5 || cs[0] != 100;
  return fails;
}
