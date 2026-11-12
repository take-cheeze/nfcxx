// EXPECT: 0
// STDOUT: same
// The inliner and the EH frame passes (--strip-leaf-eh): small functions with destructors, noexcept members and calls that
// cannot throw are inlined and lose their EH stack entries; the ones that can throw must keep theirs. Each check adds to `bad`
// when the result is wrong. The order in which destructors run is printed and compared with the gcc backend.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <memory>
#include <stdexcept>

static int bad;
#define CHECK(c) do { if (!(c)) { bad++; std::printf("check failed: line %d\n", __LINE__); } } while (0)

struct Tracer {
  const char* name;
  explicit Tracer(const char* n) : name(n) { std::printf("+%s ", name); }
  Tracer(const Tracer& o) : name(o.name) { std::printf("+copy(%s) ", name); }
  ~Tracer() { std::printf("-%s ", name); }
};

struct Counter {
  int n = 0;
  int get() const noexcept { return n; }
  void bump() noexcept { ++n; }
};

// accessors with no throwing call: inlined, no frame needed
static int pick(const std::vector<int>& v, std::size_t i) noexcept { return v[i]; }
static std::size_t total(const std::vector<int>& v) noexcept { std::size_t s = 0; for (int x : v) s += x; return s; }

// a function with a local object that calls something that throws: its cleanup frame must stay
[[gnu::noinline]] static void may_throw(int x) { if (x > 2) throw std::runtime_error("big"); }
static int guarded_local(int x) {
  Tracer t("local");
  Counter c;
  c.bump();
  may_throw(x);
  c.bump();
  return c.get();
}

// a noexcept wrapper around a throwing call, called inside a try: it terminates, so it is only run with x <= 2
static int noexcept_wrapper(int x) noexcept { may_throw(x); return x; }

// the same, but the wrapper itself is inlined into a caller that has a try block and a local with a destructor
static int through_try(int x) {
  Tracer outer("outer");
  try {
    Tracer inner("inner");
    return noexcept_wrapper(x) + guarded_local(x);
  } catch (const std::exception& e) {
    return -100;
  }
}

// a destructor that makes only nothrow calls (a member's destructor), inside a function that throws
struct Holder {
  std::shared_ptr<int> p;
  std::string s;
  Holder() : p(std::make_shared<int>(7)), s("held") {}
  ~Holder() { std::printf("~Holder(%s) ", s.c_str()); }
};
static int throw_with_holder(bool t) {
  Holder h;
  Counter c;
  c.bump();
  if (t) throw 42;
  return *h.p + c.get();
}

// a constructor that throws after a member is built: the member is destroyed
struct Pair {
  Tracer a;
  Tracer b;
  Pair(bool t) : a("pairA"), b("pairB") { if (t) throw std::string("ctor"); }
};

// a rethrow through inlined frames
static int rethrower(int x) {
  Tracer t("rethrow");
  try { may_throw(x); } catch (...) { throw; }
  return x;
}

// a comparator that throws, called by qsort (a C function the module does not define): the caller's frame must stay
static int cmp_throw(const void* a, const void* b) {
  if (*static_cast<const int*>(a) == 3) throw 7;
  return *static_cast<const int*>(a) - *static_cast<const int*>(b);
}
static int sort_it(bool t) {
  Tracer tr("sorter");
  int v[4] = {4, 1, 3, 2};
  if (!t) { v[2] = 5; }
  std::qsort(v, 4, sizeof(int), cmp_throw);
  return v[0];
}

int main() {
  std::vector<int> v{1, 2, 3, 4};
  CHECK(pick(v, 2) == 3);
  CHECK(total(v) == 10);

  CHECK(guarded_local(1) == 2);
  int caught = 0;
  try { guarded_local(5); } catch (const std::runtime_error&) { caught = 1; }
  CHECK(caught == 1);
  std::printf("| ");

  CHECK(through_try(1) == 3);
  CHECK(through_try(2) == 4);
  std::printf("| ");

  caught = 0;
  try { throw_with_holder(true); } catch (int e) { caught = e; }
  CHECK(caught == 42);
  CHECK(throw_with_holder(false) == 8);
  std::printf("| ");

  std::string msg;
  try { Pair p(true); } catch (const std::string& s) { msg = s; }
  CHECK(msg == "ctor");
  { Pair q(false); }
  std::printf("| ");

  caught = 0;
  try { rethrower(9); } catch (const std::runtime_error&) { caught = 1; }
  CHECK(caught == 1);
  CHECK(rethrower(1) == 1);
  std::printf("| ");

  caught = 0;
  try { sort_it(true); } catch (int e) { caught = e; }
  CHECK(caught == 7);
  CHECK(sort_it(false) == 1);
  std::printf("\n");
  return bad;
}
