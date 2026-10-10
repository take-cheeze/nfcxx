// EXPECT: 0
// STDOUT: same
// C++20: ranges and views, concepts, <=> defaulted comparison, consteval, fold expressions, templated lambdas, designated
// initializers, structured bindings over a map. (std::format instantiates a long double formatter: refused, docs/notes/pathb-hosted.md.)
#include <algorithm>
#include <compare>
#include <concepts>
#include <cstdio>
#include <numeric>
#include <ranges>
#include <string>
#include <vector>
#include <map>
#include <array>

template <std::integral T> constexpr T sq(T x) { return x * x; }
template <typename T> concept Printable = requires(T t) { std::to_string(t); };
template <Printable T> std::string show(T t) { return std::to_string(t); }

struct P {
  int x, y;
  auto operator<=>(const P &) const = default;
};

consteval int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

template <class... A> int sum_all(A... a) { return (a + ... + 0); }

int main() {
  std::vector<int> v = {5, 3, 8, 1, 9, 2, 7};
  auto evens = v | std::views::filter([](int x) { return x % 2 == 0; });
  for (int x : evens) std::printf("%d ", x);
  std::printf("\n");
  auto sq2 = v | std::views::transform([](int x) { return x * x; }) | std::views::take(4);
  for (int x : sq2) std::printf("%d ", x);
  std::printf("\n");
  for (int x : std::views::iota(1, 6) | std::views::reverse) std::printf("%d ", x);
  std::printf("\n");
  std::ranges::sort(v);
  std::printf("sorted %d %d found %d\n", v.front(), v.back(), (int)std::ranges::binary_search(v, 8));
  std::printf("%d %d\n", (int)std::ranges::count_if(v, [](int x) { return x > 4; }), *std::ranges::max_element(v));
  std::printf("%d %s\n", sq(7), show(12).c_str());
  P a{1, 2}, b{1, 3};
  std::printf("spaceship %d %d %d\n", (int)(a < b), (int)(a == b), (int)((a <=> b) == std::strong_ordering::less));
  constexpr int f10 = fib(10);
  std::printf("consteval %d fold %d\n", f10, sum_all(1, 2, 3, 4));
  std::map<std::string, int> m = {{"a", 1}, {"b", 2}};
  for (auto &[k, val] : m) std::printf("%s%d ", k.c_str(), val);
  std::printf("\n");
  std::array<int, 4> arr = {4, 3, 2, 1};
  std::printf("%d\n", std::accumulate(arr.begin(), arr.end(), 0));
  auto lam = []<typename T>(T x) { return x + 1; };
  std::printf("%d %g\n", lam(1), lam(1.5));
  struct D { int a; int b; };
  D d{.a = 1, .b = 2};
  std::printf("designated %d %d\n", d.a, d.b);
  return 0;
}
