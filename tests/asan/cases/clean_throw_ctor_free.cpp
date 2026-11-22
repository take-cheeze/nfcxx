// CLEAN
// ASAN-OPTIONS: detect_leaks=1
// ASAN-ONLY: pathb
// (the gcc backend uses EDG's own EH runtime, which this does not test)
// An exception object whose construction throws is freed (gcc's __cxa_free_exception), after the members it built are
// destroyed: a member's constructor that throws, an argument of the object's constructor that throws before anything
// is built, and an aggregate whose second member throws. With LeakSanitizer on, a leaked object is a report. The exit
// code is the number of wrong results.
#include <string>
static int bad, live;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)
struct S {
  std::string n;
  S(const char *p) : n(p) { ++live; }
  S(const S &o) : n(o.n) { ++live; }
  ~S() { --live; }
};
struct Boom {
  S a;
  Boom(int k) : a("member") { if (k) throw k; }
};
static int arg(int x) {
  if (x) throw x + 100;
  return x;
}
struct E {
  S a;
  S b;
};
static S second(int x) {
  if (x) throw x + 200;
  return S("second");
}
struct Plain {
  long v[8];
  Plain(int v0) : v{v0} {}
};
int main() {
  for (int i = 0; i < 3; i++) {
    try { throw Boom(1); } catch (int e) { CHECK(e == 1); }
    try { throw Plain(arg(2)); } catch (int e) { CHECK(e == 102); } catch (Plain &) { ++bad; }
    try { throw E{S("first"), second(3)}; } catch (int e) { CHECK(e == 203); }
    try { throw E{S("first"), second(0)}; } catch (E &e) { CHECK(e.b.n == "second"); }
    try { throw std::string(std::string(4096, 'x')); } catch (std::string &s) { CHECK(s.size() == 4096); }
  }
  CHECK(live == 0);
  return bad;
}
