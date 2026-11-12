// EXPECT: 0
// A function-local static with a constant initializer (a constexpr constructor) and a non-trivial destructor: EDG makes its
// initialization static and leaves no guard, and Path B registered the destructor with __cxa_atexit at every call of the
// function, so the object was destroyed once per call at exit (tests/poly ops.cpp: double free in std::vector's destructor).
#include <unistd.h>
#include <vector>

static int destroyed;

struct Counted {
  constexpr Counted() {}
  ~Counted() {
    if (++destroyed > 1) _exit(3);  // a second destruction of the one object
  }
  int n = 0;
};

static Counted& counted() {
  static Counted c;
  return c;
}

static std::vector<int>& values() {
  static std::vector<int> v;
  return v;
}

int main() {
  for (int i = 0; i < 5; ++i) counted().n += 1;
  for (int i = 0; i < 5; ++i) values().push_back(i);  // freed once at exit, not once per call
  return counted().n == 5 && values().size() == 5 ? 0 : 1;
}
