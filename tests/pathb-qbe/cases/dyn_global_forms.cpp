// Path B: the forms of namespace-scope dynamic initialization that the lowering turns into the __sti__ routine:
// a const object initialized by a call (written through an lvalue_adjust), references bound to new objects,
// aggregates and arrays of objects, an anonymous-namespace object, static data members, and a GNU init_priority
// object (it gets its own initialization routine, which runs first). Constructor calls, __cxa_atexit registrations
// and destruction order must print exactly what the gcc backend prints.
// EXPECT: 48
// STDOUT: same
extern "C" int printf(const char*, ...);
struct A { int x; A(int v):x(v){ printf("A(%d)\n", v);} A():x(0){} ~A(){ printf("~A(%d)\n", x);} };
struct Agg { A a; A b[2]; int k; };
int f(int v) { printf("f %d\n", v); return v; }
const int c1 = f(3);
int &r1 = *new int(4);
A &ra = *new A(5);
Agg ag = { A(1), { A(2), A(3) }, f(9) };
namespace { A anon(6); }
A multi[2][2] = { { A(1), A(2) }, { A(3), A(4) } };
__attribute__((init_priority(150))) A early(7);
A late(8);
A tl(9);
struct S { static A sm; static const int ci; };
A S::sm(11);
const int S::ci = f(12);
int main() { A loc[2] = { A(20), A(21) }; Agg la = { A(30), {A(31), A(32)}, 5 }; static A ls(40);
  return c1 + r1 + ra.x + ag.k + anon.x + S::ci + tl.x; }
