// EXPECT: 0
// STDOUT: same
// std::tuple, std::pair, std::optional, std::variant (visit, holds_alternative, index, valueless-free use), std::array,
// structured bindings, std::tie, std::apply, std::get, comparisons; output compared with the gcc backend.
#include <array>
#include <cstdio>
#include <optional>
#include <string>
#include <tuple>
#include <utility>
#include <variant>

struct Loud {
  int v;
  Loud(int x) : v(x) { std::printf("Loud(%d)\n", v); }
  Loud(const Loud &o) : v(o.v) { std::printf("Loud copy %d\n", v); }
  Loud(Loud &&o) noexcept : v(o.v) { std::printf("Loud move %d\n", v); }
  ~Loud() { std::printf("~Loud(%d)\n", v); }
};

struct Visitor {
  std::string operator()(int i) const { return "int " + std::to_string(i); }
  std::string operator()(double d) const { return "double " + std::to_string((int)(d * 100)); }
  std::string operator()(const std::string &s) const { return "string " + s; }
};

static std::optional<int> parse(const std::string &s) {
  if (s.empty()) return std::nullopt;
  int v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return std::nullopt;
    v = v * 10 + (c - '0');
  }
  return v;
}

static std::tuple<int, std::string, double> make() { return {7, "seven", 7.5}; }

int main() {
  auto t = make();
  std::printf("tuple %d %s %g size %zu\n", std::get<0>(t), std::get<1>(t).c_str(), std::get<2>(t), std::tuple_size<decltype(t)>::value);
  auto [a, b, c] = t;
  std::printf("bindings %d %s %g\n", a, b.c_str(), c);
  int x = 0;
  std::string y;
  std::tie(x, y, std::ignore) = make();
  std::printf("tie %d %s\n", x, y.c_str());
  auto cat = std::tuple_cat(std::make_tuple(1, 2), std::make_tuple(std::string("z"), 3.5));
  std::printf("cat %d %d %s %g\n", std::get<0>(cat), std::get<1>(cat), std::get<2>(cat).c_str(), std::get<3>(cat));
  std::printf("apply %d\n", std::apply([](int p, int q, const std::string &s, double d) { return p + q + (int)s.size() + (int)d; }, cat));
  std::printf("cmp %d %d\n", (int)(std::make_tuple(1, 2) < std::make_tuple(1, 3)), (int)(std::make_pair(2, 1) == std::make_pair(2, 1)));

  // std::pair
  std::pair<std::string, int> p{"k", 5};
  auto [pk, pv] = p;
  std::printf("pair %s %d\n", pk.c_str(), pv);

  // optional
  for (const char *s : {"123", "", "12x", "0"}) {
    auto o = parse(s);
    if (o) std::printf("parsed '%s' -> %d\n", s, *o);
    else std::printf("parsed '%s' -> none (%d)\n", s, o.value_or(-1));
  }
  {
    std::optional<Loud> ol;
    ol.emplace(11);
    std::optional<Loud> ol2 = ol;
    ol.reset();
    std::printf("opt has %d %d\n", (int)ol.has_value(), (int)ol2.has_value());
  }

  // variant
  std::variant<int, double, std::string> v = 42;
  std::printf("variant %zu %s\n", v.index(), std::visit(Visitor{}, v).c_str());
  v = 2.5;
  std::printf("variant %zu %s\n", v.index(), std::visit(Visitor{}, v).c_str());
  v = std::string("text");
  std::printf("variant %zu %s %d\n", v.index(), std::visit(Visitor{}, v).c_str(), (int)std::holds_alternative<std::string>(v));
  std::printf("get_if %d %d\n", (int)(std::get_if<int>(&v) != nullptr), (int)(std::get_if<std::string>(&v) != nullptr));
  {
    std::variant<Loud, int> lv(std::in_place_type<Loud>, 5);
    lv = 9;
    std::printf("variant assigned %zu\n", lv.index());
  }
  std::variant<std::monostate, int> mono;
  std::printf("monostate %zu\n", mono.index());
  auto lam = [](auto &&arg) -> int {
    using T = std::decay_t<decltype(arg)>;
    if constexpr (std::is_same_v<T, int>) return 1;
    else if constexpr (std::is_same_v<T, double>) return 2;
    else return 3;
  };
  std::printf("visit lambda %d %d %d\n", std::visit(lam, std::variant<int, double, char>(1)),
              std::visit(lam, std::variant<int, double, char>(1.0)), std::visit(lam, std::variant<int, double, char>('c')));

  // std::array
  std::array<int, 5> arr = {5, 4, 3, 2, 1};
  int sum = 0;
  for (int e : arr) sum += e;
  std::printf("array %zu %d front %d back %d at %d\n", arr.size(), sum, arr.front(), arr.back(), arr.at(2));
  std::array<std::string, 3> strs = {"a", "bb", "ccc"};
  std::printf("strs %s\n", (strs[0] + strs[1] + strs[2]).c_str());
  auto [a0, a1, a2, a3, a4] = arr;
  std::printf("array bindings %d %d %d %d %d\n", a0, a1, a2, a3, a4);
  return 0;
}
