// EXPECT: 0
// C++ exceptions, part 1 (Path B): throw and catch of scalars and class objects, catch by base reference,
// catch by value, catch (...), pointers, rethrow, nested try, a throw across several frames.
// Every check adds to `bad` when the result is wrong; the exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)

struct Base { int b; Base(int x) : b(x) {} virtual ~Base() {} virtual int id() const { return 1; } };
struct Derived : Base { int d; Derived(int x, int y) : Base(x), d(y) {} int id() const override { return 2; } };
struct Plain { int v; long w; };

static int t_int(int x) { try { if (x > 0) throw x * 3; return -1; } catch (int e) { return e; } }
static long t_long() { try { throw 5000000000L; } catch (long e) { return e; } }
static char t_char() { try { throw 'q'; } catch (char c) { return c; } }
static double t_double() { try { throw 2.5; } catch (double d) { return d; } }
static int t_ptr() { static int g = 77; try { throw &g; } catch (int *p) { return *p; } }
static const char *t_str() { try { throw "text"; } catch (const char *s) { return s; } }
static int t_plain() { try { throw Plain{4, 9}; } catch (Plain p) { return p.v + (int)p.w; } }
static int t_ref() { try { throw Plain{6, 1}; } catch (const Plain &p) { return p.v * 10 + (int)p.w; } }
static int t_base_ref() { try { throw Derived(3, 4); } catch (Base &b) { return b.b * 100 + b.id() * 10 + 1; } }
static int t_base_val() { try { throw Derived(5, 6); } catch (Base b) { return b.b; } }
static int t_derived_first() {
  try { throw Derived(1, 2); }
  catch (Derived &d) { return d.d; }
  catch (Base &) { return -1; }
}
static int t_order() {
  try { throw Derived(1, 2); }
  catch (Base &) { return 10; }
  catch (Derived &) { return 20; }
}
static int t_ellipsis(int k) {
  try { if (k == 0) throw 1; if (k == 1) throw 'c'; if (k == 2) throw Plain{1, 1}; return 9; }
  catch (...) { return 7; }
}
static int t_select(int k) {
  try { if (k == 0) throw 1; if (k == 1) throw 'c'; throw 2.0; }
  catch (int) { return 100; }
  catch (char) { return 200; }
  catch (...) { return 300; }
}
static int t_none() { int r = 0; try { r = 5; } catch (...) { r = 99; } return r; }
static int t_nocatch_match() {
  try { try { throw 3; } catch (char) { return -1; } } catch (int e) { return e + 1; }
  return -2;
}

static int t_rethrow() {
  int seen = 0;
  try {
    try { throw 11; }
    catch (int e) { seen += e; throw; }
  } catch (int e) { seen += e * 10; }
  return seen;
}
static int t_rethrow_obj() {
  try {
    try { throw Derived(8, 9); }
    catch (Base &) { throw; }
  } catch (Derived &d) { return d.d; }
  return -1;
}
static int t_throw_other() {
  try { try { throw 1; } catch (int) { throw 'x'; } } catch (char c) { return c; }
  return 0;
}
static int t_nested() {
  int r = 0;
  try {
    try { throw 1; } catch (int a) { r += a; try { throw 2; } catch (int b) { r += b * 10; } }
    r += 100;
    throw 3;
  } catch (int c) { r += c * 1000; }
  return r;
}
static int t_nested_noreach() {
  int r = 0;
  try { try { r += 1; } catch (...) { r += 100; } r += 10; } catch (...) { r += 1000; }
  return r;
}

static int deep3(int n) { if (n == 0) throw n + 42; return n; }
static int deep2(int n) { return deep3(n) + 1; }
static int deep1(int n) { return deep2(n) + 1; }
static int deep0(int n) { return deep1(n) + 1; }
static int t_frames(int n) { try { return deep0(n); } catch (int e) { return e; } }

static int t_loop() {
  int caught = 0;
  for (int i = 0; i < 10; i++) {
    try { if (i % 3 == 0) throw i; caught += 100; } catch (int e) { caught += e; }
  }
  return caught;
}
static int t_in_catch_return() {
  for (int i = 0; i < 3; i++) { try { throw i; } catch (int e) { if (e == 1) return 50 + e; } }
  return 0;
}
static int t_break_continue() {
  int n = 0;
  for (int i = 0; i < 6; i++) {
    try { if (i == 1) continue; if (i == 4) break; throw i; } catch (int e) { n += e; }
  }
  return n;
}

int main() {
  CHECK(t_int(2) == 6); CHECK(t_int(0) == -1);
  CHECK(t_long() == 5000000000L);
  CHECK(t_char() == 'q');
  CHECK(t_double() == 2.5);
  CHECK(t_ptr() == 77);
  CHECK(t_str()[0] == 't' && t_str()[3] == 't');
  CHECK(t_plain() == 13);
  CHECK(t_ref() == 61);
  CHECK(t_base_ref() == 321);
  CHECK(t_base_val() == 5);
  CHECK(t_derived_first() == 2);
  CHECK(t_order() == 10);
  CHECK(t_ellipsis(0) == 7 && t_ellipsis(1) == 7 && t_ellipsis(2) == 7 && t_ellipsis(3) == 9);
  CHECK(t_select(0) == 100 && t_select(1) == 200 && t_select(2) == 300);
  CHECK(t_none() == 5);
  CHECK(t_nocatch_match() == 4);
  CHECK(t_rethrow() == 121);
  CHECK(t_rethrow_obj() == 9);
  CHECK(t_throw_other() == 'x');
  CHECK(t_nested() == 3121);
  CHECK(t_nested_noreach() == 11);
  CHECK(t_frames(0) == 42 && t_frames(1) == 4);
  CHECK(t_loop() == 0 + 3 + 6 + 9 + 600 + 0 * 0);
  CHECK(t_in_catch_return() == 51);
  CHECK(t_break_continue() == 0 + 2 + 3);
  return bad;
}
