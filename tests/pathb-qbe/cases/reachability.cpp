// EXPECT: 42
// Code nothing reaches is not emitted. The unreachable routines below use constructs the emitter refuses
// (long double, volatile), so the program only builds when they are left out: an unused static function, an
// unused inline function, an unused template instance and an unused class with a virtual function (its vtable).
// The reachable routines (a static function called from main, an inline function reached through a static
// function, a vtable used through a call) must stay.

static long double unused_static(long double x) { return x * 2; }

inline int unused_inline(volatile int *p) { return *p + 1; }

template <class T> T unused_template(volatile T *p) { return *p; }
template int unused_template<int>(volatile int *);

struct Unused {
  virtual long double f() { return 1.0L; }
};

inline int helper(int x) { return x + 1; }
static int used_static(int x) { return helper(x) * 2; }

struct Used {
  virtual int g() { return 20; }
};

int main() {
  Used u;
  Used *p = &u;
  return used_static(10) + p->g();
}
