// EXPECT: 0
// C++ exceptions, part 3 (Path B): function-try-blocks (functions and constructors), noexcept functions,
// a pointer to a derived class caught as a pointer to its base, a throw through a virtual call and through a function
// pointer, a template throwing a class template instance, a handler that itself catches, an exception thrown from a
// handler while another is being handled (nested exception objects), and recursion with handlers at several levels.
// The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)

static long trace;
static void ev(int d) { trace = trace * 10 + d; }

struct G { int id; G(int i) : id(i) { ev(i); } ~G() { ev(id + 5); } };

// ---- function-try-block of a function
static int ftb(int k) try {
  G g(1);
  if (k) throw k;
  return 100;
} catch (int e) {
  ev(4);
  return e + 200;
}
// ---- function-try-block of a constructor: the handler runs after members are destroyed, then the exception is rethrown
struct M {
  G a;
  M(int k) try : a(1) { ev(2); if (k) throw k; } catch (int) { ev(4); }
  ~M() { ev(9); }
};
// ---- noexcept functions that do not throw and call a throwing function inside a try
static int quiet(int x) noexcept { try { if (x) throw x; } catch (int e) { return e + 1; } return 0; }
// ---- derived pointer caught as base pointer
struct A { int a; virtual ~A() {} virtual int w() { return 1; } };
struct B : A { int b; int w() override { return 2; } };
static int ptrconv() {
  B b; b.a = 5; b.b = 6;
  try { throw &b; } catch (A *p) { return p->a * 10 + p->w(); }
  return -1;
}
static int const_ptr() {
  static int v = 3;
  try { throw &v; } catch (const int *p) { return *p; }
  return -1;
}
static int void_ptr() {
  static int v = 9;
  try { throw &v; } catch (void *p) { return *(int *)p; }
  return -1;
}
// ---- throw through a virtual call and a function pointer
struct Thrower { virtual void go(int n) { if (n) throw n; } virtual ~Thrower() {} };
struct Thrower2 : Thrower { void go(int n) override { G g(1); Thrower::go(n + 1); } };
static void viafp(void (*f)(int), int n) { G g(2); f(n); }
static void plain_throw(int n) { throw n * 2; }
static long virtual_throw() {
  trace = 0; Thrower2 t; Thrower *p = &t; int got = 0;
  try { p->go(4); } catch (int e) { got = e; }
  return trace * 100 + got;                // events 1 6 (trace 16), result 5
}
static long fp_throw() {
  trace = 0; int got = 0;
  try { viafp(plain_throw, 6); } catch (int e) { got = e; }
  return trace * 100 + got;                // events 2 7, result 12
}
// ---- class template thrown
template <class T> struct Box { T v; };
template <class T> static T unbox(int k, T x) { try { if (k) throw Box<T>{x}; } catch (Box<T> &b) { return b.v; } return T(); }
// ---- exception thrown in a handler, caught outside; the first exception object is destroyed
struct Obj { int id; Obj(int i) : id(i) {} Obj(const Obj &o) : id(o.id) {} ~Obj() { ev(id); } };
static long handler_throws() {
  trace = 0;
  try {
    try { throw Obj(1); }
    catch (Obj &) { ev(8); throw Obj(2); }
  } catch (Obj &o) { ev(o.id + 3); }
  return trace;                            // 8 1 5 2  (inner exception object is destroyed after the new throw leaves the handler)
}
// ---- handler that itself uses try/catch (nested handlers with their own exception stack entries)
static int nested_in_handler() {
  int r = 0;
  try { throw 1; }
  catch (int a) {
    r += a;
    try { throw 'c'; } catch (char c) { r += c; }
    r += 1000;
  }
  return r;
}
// ---- a recursive function that throws at the bottom and catches at every second level
static int rec(int n) {
  if (n == 0) throw 0;
  try { return rec(n - 1) + 1; } catch (int e) { if (n % 2) throw e + 1; return e + 100; }
}

int main() {
  trace = 0; CHECK(ftb(0) == 100); CHECK(trace == 16);
  trace = 0; CHECK(ftb(5) == 205); CHECK(trace == 164);
  { int caught = 0; trace = 0; try { M m(3); } catch (int e) { caught = e; } CHECK(caught == 3); CHECK(trace == 1264); }
  trace = 0; { M m(0); } CHECK(trace == 1296);
  CHECK(quiet(0) == 0 && quiet(4) == 5);
  CHECK(ptrconv() == 52);
  CHECK(const_ptr() == 3);
  CHECK(void_ptr() == 9);
  CHECK(virtual_throw() == 1605);
  CHECK(fp_throw() == 2712);
  CHECK(unbox<int>(1, 7) == 7 && unbox<int>(0, 7) == 0);
  CHECK(unbox<double>(1, 1.5) == 1.5);
  CHECK(handler_throws() == 8152);
  CHECK(nested_in_handler() == 1100);
  { int r = 0; try { r = rec(3); } catch (int e) { r = -e; } CHECK(r == 102); }
  { int r = 0; try { r = rec(4); } catch (int e) { r = -e; } CHECK(r == 103); }
  return bad;
}
