// EXPECT: 0
// C++ exceptions, part 4 (Path B): multiple and virtual inheritance catch matching, new/delete and new[] with a throwing
// constructor, a function-local static whose initializer throws, goto/switch/return inside try, slicing on catch by value.
// The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)
static long trace;
static void ev(int d) { trace = trace * 10 + d; }
struct G { int id; G(int i) : id(i) { ev(i); } ~G() { ev(id + 5); } };

// multiple inheritance: catch the second base by pointer and reference
struct P { int p; virtual ~P() {} };
struct Q { int q; virtual ~Q() {} };
struct PQ : P, Q { int pq; };
static int mi_ref() { PQ x; x.p = 1; x.q = 2; x.pq = 3; try { throw x; } catch (Q &q) { return q.q; } return -1; }
static int mi_ptr() { PQ x; x.p = 1; x.q = 2; x.pq = 3; try { throw &x; } catch (Q *q) { return q->q; } return -1; }
// virtual inheritance
struct V { int v; virtual ~V() {} };
struct D1 : virtual V {};
struct D2 : virtual V {};
struct DD : D1, D2 { int dd; };
static int vi_ref() { DD x; x.v = 7; try { throw x; } catch (V &v) { return v.v; } return -1; }
// new with throwing constructor: memory is freed, members destroyed
struct N { G g; N(int k) : g(1) { if (k) throw k; } ~N() { ev(9); } };
static long new_throws() { trace = 0; try { N *p = new N(1); delete p; } catch (int) { ev(4); } return trace; }
// array new with throwing element constructor
static int ctor_count;
struct E3 { E3() { if (ctor_count == 2) throw 3; ctor_count++; ev(1); } ~E3() { ev(2); } };
static long vec_new() { trace = 0; ctor_count = 0; try { E3 *a = new E3[4]; delete[] a; } catch (int) { ev(4); } return trace; }
// static local with throwing initializer
static int init_calls;
static int mayfail(int k) { init_calls++; if (k) throw 5; return 1; }
static int local_static(int k) { static int v = mayfail(k); return v; }
// throw in destructor-less scope inside a loop with goto
static int with_goto() {
  int n = 0;
  for (int i = 0; i < 3; i++) {
    try { if (i == 1) goto skip; n += 1; } catch (...) {}
  skip:
    n += 10;
  }
  return n;
}
// switch inside try
static int sw(int k) { try { switch (k) { case 0: return 1; case 1: throw 2; default: break; } } catch (int e) { return e; } return 9; }
// exception object with a non-trivial copy and a class with a vtable thrown by value
struct W { virtual int f() { return 1; } int x; W(int a) : x(a) {} };
struct W2 : W { int f() override { return 2; } W2(int a) : W(a) {} };
static int slice() { try { throw W2(4); } catch (W w) { return w.f() * 10 + w.x; } return 0; }
static int noslice() { try { throw W2(4); } catch (W &w) { return w.f() * 10 + w.x; } return 0; }

int main() {
  CHECK(mi_ref() == 2); CHECK(mi_ptr() == 2);
  CHECK(vi_ref() == 7);
  CHECK(new_throws() == 164);
  CHECK(vec_new() == 11224);
  init_calls = 0;
  { int r = 0; try { r = local_static(1); } catch (int e) { r = e; } CHECK(r == 5); }
  CHECK(local_static(0) == 1); CHECK(local_static(0) == 1); CHECK(init_calls == 2);
  CHECK(with_goto() == 32);
  CHECK(sw(0) == 1 && sw(1) == 2 && sw(2) == 9);
  CHECK(slice() == 14); CHECK(noslice() == 24);
  return bad;
}
