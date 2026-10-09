// Path B: constructors in every context the front end lowers: default member initializers, delegating and
// inherited constructors, copies into arguments and results, lambda captures, thrown objects, arrays created
// with new[] (the operator delete[] address is passed to the vector helpers), references bound to temporaries,
// local classes and a template instance. The constructor and destructor calls print, and must match the gcc backend.
// EXPECT: 243
// STDOUT: same
extern "C" int printf(const char*, ...);
struct A { int x; A(int v):x(v){ printf("A(%d)\n", v);} A(const A&o):x(o.x+100){ printf("copy\n"); } A():x(0){} ~A(){ printf("~A(%d)\n", x);} };
struct M { A a{3}; int k = 5; A b = A(4); M() = default; M(int) : M() { k = 6; } };
struct I : M { using M::M; };
A mk(int v) { return A(v); }
struct W { A a; W(A p) : a(p) {} };
template <class T> struct Box { T t; Box(T v) : t(v) {} };
Box<A> gbox(A(55));
A garr[] = { A(1), A(2), A(3) };
constexpr int sq(int v) { return v * v; }
int gs = sq(4);
struct Lazy { A a; Lazy() : a(77) {} } glazy;
int main() {
  M m; M m2(1); I i(1);
  W w(A(9));
  A c = mk(8);
  auto lam = [c]() { return c.x; };
  int r = lam();
  try { throw A(12); } catch (const A &e) { r += e.x; }
  A *pa = new A[2]{ A(1), A(2) };
  delete[] pa;
  A &&rr = mk(3);
  A ra2[1] = { A(7) }; for (A v : ra2) r += v.x;
  struct Loc { A a; Loc() : a(2) {} } loc;
  A copy = loc.a;
  return r + gs;
}
