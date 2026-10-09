// EXPECT: 0
// C++ exceptions, part 7 (Path B): the exceptions the language itself throws (dynamic_cast to a reference that does not
// match throws std::bad_cast, here caught with catch (...)), and covariant returns with a this-adjusting thunk in a
// class with a second base (the thunk body is an enk_result_of_overriding_function node).
// The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) bad++; } while (0)
struct A { virtual ~A() {} virtual A *self() { return this; } int a; A() : a(1) {} };
struct B : A { B *self() override { return this; } int b; B() : b(2) {} };
struct C { virtual ~C() {} int c; C() : c(3) {} };
struct M : C, B {};      // B is the second base: its virtual functions are reached through thunks
struct M2 : C, B { M2 *self() override { return this; } int m2 = 0; };   // covariant return M2 * for B * (second base)
static int cov2() {
  M2 m; B *pb = &m; A *pa = &m;
  B *r1 = pb->self();      // through B::self's slot: M2::self returns M2 *, the wrapper converts it to B *
  A *r2 = pa->self();
  return r1 == pb && r2 == pa && m.self() == &m;
}
static int cov() { M m; A *p = &m; A *q = p->self(); B *r = m.self(); return q == p && r == (B *)&m; }
static int bad_cast_ref() { A a; try { (void)dynamic_cast<B &>(a); } catch (...) { return 1; } return 0; }
static int bad_cast_ok() { B b; A &r = b; try { return dynamic_cast<B &>(r).b; } catch (...) { return 0; } }
static int cross_cast() { M m; C *c = &m; try { return dynamic_cast<B &>(*c).b; } catch (...) { return 0; } }
static void fn() {}
static int throw_fnptr() { try { throw &fn; } catch (void (*p)()) { p(); return 1; } catch (...) { return 0; } }
int main() {
  CHECK(cov()); CHECK(cov2()); CHECK(bad_cast_ref() == 1); CHECK(bad_cast_ok() == 2); CHECK(cross_cast() == 2);
  CHECK(throw_fnptr() == 1);
  return bad;
}
