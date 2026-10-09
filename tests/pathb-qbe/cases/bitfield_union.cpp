// EXPECT: 0
// Bit-fields in a union and in classes with virtual bases / virtual functions, with aggregate and default member
// initializers, at namespace scope and local. The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

union BU { unsigned a : 3; unsigned b : 5; int whole; };
union BU2 { struct { unsigned x : 4; unsigned y : 4; } s; unsigned char raw; };
struct HasU { int pre; union { unsigned lo : 6; unsigned hi : 10; } u; int post; };
union BS { signed s : 4; unsigned u : 4; };

BU g1 = {5};
BU2 g2 = {{3, 12}};
HasU g3 = {1, {33}, 2};
BS g4 = {-3};
BU ga[2] = {{1}, {2}};

struct VB { int vbv; VB() : vbv(7) {} };
struct D : virtual VB {
  unsigned f1 : 5;
  int f2 : 7;
  int plain;
  D() : f1(9), f2(-3), plain(4) {}
};
struct D2 : virtual VB {
  unsigned f1 : 3 = 5;
  int f2 : 9 = -100;
  int n = 8;
};
struct V { virtual int g() { return 1; } unsigned q : 6; int r : 11; };
struct V2 : V { unsigned w : 3 = 6; int m = 3; int g() override { return 2; } };

// Constant-initialized (static data) objects of classes with a vptr and bit-field default member initializers, an
// anonymous union with a bit-field, a constexpr union. Classes with a virtual base are never constant-initialized
// (their constructor cannot be constexpr): they are zeroed and constructed at start-up (D, D2 above).
struct W { union { unsigned a : 3; int b; }; int c = 2; constexpr W() : b(5) {} };
union U2 { unsigned x : 3; int y; constexpr U2() : x(5) {} };
V2 gv2;
W gw;
constexpr U2 gu;

int main() {
  BU l1 = {6};
  CHECK(l1.a == 6);
  l1.b = 17;
  CHECK(l1.b == 17 && (l1.whole & 31) == 17);
  BU2 l2 = {{15, 1}};
  CHECK(l2.s.x == 15 && l2.s.y == 1 && l2.raw == 0x1f);
  HasU l3 = {4, {63}, 6};
  CHECK(l3.pre == 4 && l3.u.lo == 63 && l3.post == 6);
  BS l4 = {-8};
  CHECK(l4.s == -8 && l4.u == 8);
  BU la[3] = {{1}, {2}, {3}};
  CHECK(la[2].a == 3);

  CHECK(g1.a == 5 && g2.s.x == 3 && g2.s.y == 12 && g2.raw == 0xc3);
  CHECK(g3.pre == 1 && g3.u.lo == 33 && g3.post == 2);
  CHECK(g4.s == -3 && g4.u == 13);
  CHECK(ga[0].a == 1 && ga[1].a == 2);

  D d;
  CHECK(d.f1 == 9 && d.f2 == -3 && d.plain == 4 && d.vbv == 7);
  d.f2 = 60; d.f1 = 31;
  CHECK(d.f1 == 31 && d.f2 == 60 && d.vbv == 7);
  D2 d2;
  CHECK(d2.f1 == 5 && d2.f2 == -100 && d2.n == 8 && d2.vbv == 7);
  V2 v2;
  v2.q = 40; v2.r = -500;
  CHECK(v2.w == 6 && v2.m == 3 && v2.q == 40 && v2.r == -500 && v2.g() == 2);
  V *p = &v2;
  CHECK(p->g() == 2 && p->q == 40);
  CHECK(gv2.w == 6 && gv2.m == 3 && gv2.g() == 2);
  CHECK(gw.a == 5 && gw.b == 5 && gw.c == 2);
  CHECK(gu.x == 5);
  return bad;
}
