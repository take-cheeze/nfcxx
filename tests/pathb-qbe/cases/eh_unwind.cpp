// EXPECT: 0
// C++ exceptions, part 2 (Path B): destructors run during unwinding, in reverse order of construction, across several
// frames; arrays of objects; partially constructed objects; temporaries; exceptions thrown by constructors and by
// destructors of members; objects thrown by value (copy construction count); try inside a destructor-bearing scope.
// The order of events is a number in base 10 (each event appends one digit); the exit code is the number of
// wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)

static long trace;                       // digits appended in event order
static void ev(int d) { trace = trace * 10 + d; }

struct G {                               // a guard: constructor/destructor leave a digit each
  int id;
  G(int i) : id(i) { ev(i); }
  ~G() { ev(id + 5); }
};

static void thrower(int what) { if (what) throw what; }

static long t_one_frame() {
  trace = 0;
  try { G a(1); G b(2); thrower(1); ev(9); } catch (int) { ev(4); }
  return trace;                          // 1 2 7 6 4
}
static void mid(int what) { G g(3); thrower(what); ev(9); }
static void top(int what) { G g(1); mid(what); ev(9); }
static long t_frames() {
  trace = 0;
  try { top(1); } catch (int e) { ev(4); }
  return trace;                          // 1 3 8 6 4
}
static long t_no_throw() {
  trace = 0;
  try { top(0); } catch (int) { ev(9); }
  return trace;                          // 1 3 9 8 9 6
}
static long t_scopes() {
  trace = 0;
  try {
    G a(1);
    { G b(2); }                          // leaves normally: 2 7
    G c(3);
    thrower(1);
  } catch (...) { ev(4); }
  return trace;                          // 1 2 7 3 8 6 4
}
static long t_array() {
  trace = 0;
  try {
    G arr[3] = {G(1), G(2), G(3)};
    thrower(1);
  } catch (int) { ev(4); }
  return trace;                          // 1 2 3 8 7 6 4
}

struct Ctor {                            // the constructor throws after building a member
  G m;
  Ctor(int k) : m(1) { ev(2); if (k) throw k; ev(3); }
  ~Ctor() { ev(9); }
};
static long t_ctor_throws() {
  trace = 0;
  try { Ctor c(1); ev(9); } catch (int) { ev(4); }
  return trace;                          // 1 2 6 4   (member destroyed, Ctor's destructor not run)
}
static long t_ctor_ok() {
  trace = 0;
  try { Ctor c(0); } catch (int) { ev(8); }
  return trace;                          // 1 2 3 9 6
}
struct Two {                             // second member throws: first is destroyed
  G a, b;
  Two(int k) : a(1), b(k ? throw 7 : 2) { ev(9); }
};
static long t_member_throws() {
  trace = 0;
  try { Two t(1); } catch (int) { ev(4); }
  return trace;                          // 1 6 4
}

static long t_temp() {
  trace = 0;
  try { thrower(G(1).id); } catch (int) { ev(4); }
  return trace;                          // 1 6 4  (temporary destroyed at the end of the full expression, before catch)
}

static long copies;
struct T {
  int v;
  T(int x) : v(x) {}
  T(const T &o) : v(o.v) { copies++; }
  ~T() { ev(7); }
};
static long t_thrown_object() {         // an lvalue is copied into the exception object
  trace = 0; copies = 0;
  try { T t(5); throw t; } catch (T &t) { ev(t.v); }
  return trace * 10 + copies;            // t destroyed during unwinding (7), caught (5), exception object destroyed (7)
}

static long t_rethrow_unwind() {
  trace = 0;
  try {
    G a(1);
    try { G b(2); thrower(1); } catch (int) { G c(3); ev(4); throw; }
  } catch (int) { ev(9); }
  return trace;                          // 1 2 7 3 4 8 6 9
}
static long t_catch_by_value_dtor() {
  trace = 0;
  try { throw T(1); } catch (T t) { ev(2); }
  return trace;
}
static long t_loop() {
  trace = 0;
  for (int i = 0; i < 3; i++) {
    try { G g(i + 1); if (i != 1) thrower(1); ev(9); } catch (int) { ev(4); }
  }
  return trace;                          // 1 6 4 2 9 7 3 8 4
}

static long t_return_from_try() {
  trace = 0;
  struct L { static int f() { G g(1); try { G h(2); return 5; } catch (...) { ev(9); } return 6; } };
  int r = L::f();
  return trace * 10 + r;                 // 1 2 7 6 then 5
}

int main() {
  CHECK(t_one_frame() == 12764);
  CHECK(t_frames() == 13864);
  CHECK(t_no_throw() == 139896);
  CHECK(t_scopes() == 1273864);
  CHECK(t_array() == 1238764);
  CHECK(t_ctor_throws() == 1264);
  CHECK(t_ctor_ok() == 12396);
  CHECK(t_member_throws() == 164);
  CHECK(t_temp() == 164);
  CHECK(t_thrown_object() == 7571);
  CHECK(t_rethrow_unwind() == 12734869);
  CHECK(t_catch_by_value_dtor() == 277);
  CHECK(t_loop() == 164297384);
  CHECK(t_return_from_try() == 12765);
  return bad;
}
