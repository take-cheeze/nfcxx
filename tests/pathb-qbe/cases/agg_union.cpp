// EXPECT: 0
// Aggregate constants of unions (local and namespace-scope), a union inside a struct and an array, and default
// member initializers on a class with a base class and a vptr. The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

union U { int i; float f; };
union FU { float f; int i; };
union W { char c[4]; int i; };
union V { long long a; char b; short s; };
struct S { int tag; union { int i; double d; } u; int tail; };
struct T { union U x; int y[3]; };

U g1 = {5};
W g2 = {{1, 2, 3, 4}};
S g3 = {7, {9}, 11};
T g4 = {{3}, {4, 5, 6}};
U ga[3] = {{1}, {2}, {3}};

struct Base { int b; Base() : b(1) {} virtual int f() { return b; } virtual ~Base() {} };
struct Derived : Base {
  int a = 10;
  double d = 2.5;
  char c = 'x';
  int arr[3] = {1, 2, 3};
  int f() override { return a + b; }
};
struct Derived2 : Derived {
  union { int i; float f; } un;
  int z = 77;
  Derived2() : un{42} {}
};

int main() {
  U l1 = {6};
  CHECK(l1.i == 6);
  W l2 = {{9, 8, 7, 6}};
  CHECK(l2.c[0] == 9 && l2.c[3] == 6);
  S l3 = {1, {2}, 3};
  CHECK(l3.tag == 1 && l3.u.i == 2 && l3.tail == 3);
  T l4 = {{8}, {1, 2, 3}};
  CHECK(l4.x.i == 8 && l4.y[2] == 3);
  U la[2] = {{4}, {5}};
  CHECK(la[0].i == 4 && la[1].i == 5);
  V lv = {123456789012LL};
  CHECK(lv.a == 123456789012LL);
  FU lf = {1.5f};
  CHECK(lf.f == 1.5f);
  FU lg = {};
  CHECK(lg.i == 0);

  CHECK(g1.i == 5);
  CHECK(g2.c[0] == 1 && g2.c[3] == 4);
  CHECK(g3.tag == 7 && g3.u.i == 9 && g3.tail == 11);
  CHECK(g4.x.i == 3 && g4.y[0] == 4 && g4.y[2] == 6);
  CHECK(ga[0].i == 1 && ga[1].i == 2 && ga[2].i == 3);

  Derived d;
  CHECK(d.a == 10 && d.d == 2.5 && d.c == 'x' && d.arr[2] == 3 && d.b == 1);
  CHECK(d.f() == 11);
  Base *p = &d;
  CHECK(p->f() == 11);
  Derived2 e;
  CHECK(e.un.i == 42 && e.z == 77 && e.a == 10 && e.f() == 11);
  Derived *q = new Derived;
  CHECK(q->arr[1] == 2 && q->f() == 11);
  delete q;
  return bad;
}
