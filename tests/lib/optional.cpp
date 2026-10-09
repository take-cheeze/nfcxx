// EXPECT: 0
// XFAIL-qbe: cproc rejects empty class definitions (EDG emits "struct X {}" for instantiated trait classes and empty types); see docs/notes/freestanding.md
// <optional>: empty/engaged states, value access, copy/move, emplace, reset, comparisons.
#include <optional>
#include <utility>

struct Tracker {
  static int live;
  int v;
  Tracker(int x) : v(x) { ++live; }
  Tracker(const Tracker& o) : v(o.v) { ++live; }
  Tracker(Tracker&& o) : v(o.v) { ++live; o.v = -1; }
  ~Tracker() { --live; }
};
int Tracker::live = 0;

static_assert(!std::optional<int>().has_value());
static_assert(std::optional<int>(5).has_value());
static_assert(std::optional<int>(5).value() == 5);
static_assert(std::optional<int>(5).value_or(9) == 5);
static_assert(std::optional<int>().value_or(9) == 9);
static_assert(*std::optional<int>(3) == 3);
static_assert(std::optional<int>(std::nullopt) == std::nullopt);
static_assert(std::optional<int>(4) != std::nullopt);
static_assert(std::optional<int>(4) == std::optional<int>(4));
static_assert(std::optional<int>(4) != std::optional<int>(5));
static_assert(std::optional<int>() == std::optional<int>());
static_assert(static_cast<bool>(std::optional<char>('x')));
static_assert(std::is_same_v<decltype(std::make_optional(1)), std::optional<int>>);

int main() {
  int fails = 0;
  std::optional<int> o;
  fails += o.has_value() || static_cast<bool>(o);
  o = 12;
  fails += !o || *o != 12;
  o.reset();
  fails += o.has_value();

  o.emplace(30);
  fails += o.value() != 30;
  o = std::nullopt;
  fails += o.has_value();

  std::optional<int> p(7);
  std::optional<int> q = p;              // copy
  fails += q.value() != 7;
  std::optional<int> r = std::move(p);   // move
  fails += r != q;
  fails += *r != 7;

  std::optional<int> s;
  s = q;                                 // assign engaged to empty
  fails += s.value_or(0) != 7;
  q = std::optional<int>();              // assign empty to engaged
  fails += q.has_value();

  {
    std::optional<Tracker> t;
    fails += Tracker::live != 0;
    t.emplace(5);
    fails += Tracker::live != 1 || t->v != 5;
    std::optional<Tracker> u = t;        // copy construct: +1
    fails += Tracker::live != 2;
    u.reset();
    fails += Tracker::live != 1;
    t.reset();
    fails += Tracker::live != 0;
  }
  fails += Tracker::live != 0;

  std::optional<int> sw1(1), sw2;
  sw1.swap(sw2);
  fails += sw1.has_value() || sw2.value() != 1;

  auto made = std::make_optional(42);
  fails += made.value() != 42;
  return fails;
}
