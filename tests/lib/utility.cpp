// EXPECT: 0
// <utility>: move, forward, swap, exchange, pair, make_pair, index_sequence.
#include <utility>
#include <type_traits>

static_assert(std::is_same<decltype(std::move(3)), int&&>::value);
static_assert(std::is_same<decltype(std::forward<int&>(*(int*)0)), int&>::value);
static_assert(std::is_same<decltype(std::make_pair(1, 2.0)), std::pair<int, double>>::value);
static_assert(std::is_same<std::index_sequence<0, 1, 2>, std::make_index_sequence<3>>::value);
static_assert(std::make_index_sequence<7>::size() == 7);
static_assert(std::index_sequence<>::size() == 0);

struct Counter {
  int v;
  Counter(int x) : v(x) {}
  Counter(Counter&& o) : v(o.v) { o.v = -1; }
  Counter& operator=(Counter&& o) { v = o.v; o.v = -1; return *this; }
};

constexpr int sum_pair(std::pair<int, int> p) { return p.first + p.second; }
static_assert(sum_pair(std::pair<int, int>(3, 4)) == 7);
static_assert(std::pair<int, int>(1, 2) == std::pair<int, int>(1, 2));
static_assert(std::pair<int, int>(1, 2) < std::pair<int, int>(1, 3));

template <std::size_t... I>
int sum_indices(std::index_sequence<I...>) { return (0 + ... + (int)I); }

int main() {
  int fails = 0;
  int a = 1, b = 2;
  std::swap(a, b);
  fails += a != 2 || b != 1;

  Counter c1(5), c2(6);
  std::swap(c1, c2);            // uses move ctor and move assignment
  fails += c1.v != 6 || c2.v != 5;

  int x = 10;
  int old = std::exchange(x, 20);
  fails += old != 10 || x != 20;

  Counter moved = std::move(c1);
  fails += moved.v != 6 || c1.v != -1;

  std::pair<int, double> p = std::make_pair(7, 1.5);
  fails += p.first != 7 || p.second != 1.5;
  p.swap(p);
  std::pair<int, double> q;
  fails += q.first != 0;
  p.first = 8;
  fails += (p == q) || !(p != q);

  fails += sum_indices(std::make_index_sequence<5>{}) != 10;   // 0+1+2+3+4
  fails += sum_indices(std::index_sequence<>{}) != 0;
  return fails;
}
