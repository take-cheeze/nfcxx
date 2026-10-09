// EXPECT: 0
// Bit-fields, second round: packed structs (storage units that are not aligned or reach the end of the object), a base
// class and a derived class that both have bit-fields, a class with a vptr, a union of bit-field structs, 1-bit signed
// fields, 64-bit wide fields, binding a const reference to a bit-field, a switch on a bit-field, a lambda, arrays.
// CHECK is a do { } while (0) macro on purpose: QBE miscompiles an `and` with a low mask that follows such a loop (see
// docs/notes/pathb-stage2.md, bit-fields), so this probe fails if the emitter goes back to extracting with `and`.
// The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

struct __attribute__((packed)) Pk { char c; int a : 12; unsigned b : 20; short s; unsigned long long z : 60; };
struct Base { int x; unsigned bb : 5; };
struct Der : Base { unsigned dd : 9; char tail; virtual int f() { return dd + bb; } };
struct Vt { virtual ~Vt() {} unsigned a : 4; unsigned b : 4; };
union U { unsigned w; struct { unsigned lo : 8; unsigned mid : 8; unsigned hi : 16; } p; };
struct Neg { int a : 1; int b : 31; };
struct L { unsigned long long a : 1; unsigned long long b : 63; long long c : 64; };
struct Tailpad { int x; char y; unsigned z : 3; };

static int take(unsigned v) { return (int)v + 1; }
static int takeref(const int &r) { return r * 2; }
static int sw(Neg n) { switch (n.a) { case -1: return 10; case 0: return 20; default: return 30; } }
static Tailpad mk() { Tailpad t; t.x = 1; t.y = 2; t.z = 5; return t; }

int main() {
  Pk p; p.c = 'a'; p.a = -5; p.b = 1000; p.s = -7; p.z = 0xFFFFFFFFFFFFFFFULL;
  CHECK(p.c == 'a'); CHECK(p.a == -5); CHECK(p.b == 1000); CHECK(p.s == -7); CHECK(p.z == 0xFFFFFFFFFFFFFFFULL);
  p.a += 100; CHECK(p.a == 95); p.b = 0xFFFFF; p.b++; CHECK(p.b == 0); CHECK(p.a == 95); CHECK(p.s == -7);
  CHECK(sizeof(Pk) == 14 || sizeof(Pk) == 15 || sizeof(Pk) == 16);
  Der d; d.x = 5; d.bb = 31; d.dd = 511; d.tail = 3;
  CHECK(d.f() == 542); d.dd++; CHECK(d.dd == 0); CHECK(d.bb == 31); CHECK(d.tail == 3); CHECK(d.x == 5);
  Base *bp = &d; bp->bb = 2; CHECK(d.bb == 2); CHECK(d.dd == 0);
  Vt v; v.a = 9; v.b = 15; CHECK(v.a == 9 && v.b == 15); v.a ^= 6; CHECK(v.a == 15);
  U u; u.w = 0x12345678;
  CHECK(u.p.lo == 0x78); CHECK(u.p.mid == 0x56); CHECK(u.p.hi == 0x1234);
  u.p.mid = 0xFF; CHECK(u.w == 0x1234FF78u);
  Neg n; n.a = 1; n.b = 7; CHECK(n.a == -1); CHECK(n.b == 7); CHECK(sw(n) == 10);
  n.a = 0; CHECK(sw(n) == 20);
  CHECK(take(n.b) == 8);
  CHECK(takeref(n.b) == 14);
  L l; l.a = 3; l.b = ~0ULL; l.c = -2;
  CHECK(l.a == 1); CHECK(l.b == 0x7FFFFFFFFFFFFFFFULL); CHECK(l.c == -2);
  l.c >>= 1; CHECK(l.c == -1); l.b += 1; CHECK(l.b == 0); CHECK(l.a == 1);
  Tailpad t = mk(); CHECK(t.x == 1 && t.y == 2 && t.z == 5);
  int cond = n.b > 3 ? n.b : -n.b; CHECK(cond == 7);
  auto lam = [&]() { return n.b + 1; }; CHECK(lam() == 8);
  Neg *np = &n; np->b = -1; CHECK(np->b == -1); np->b -= 3; CHECK(np->b == -4);
  Neg arr[3]; for (int i = 0; i < 3; i++) { arr[i].a = i; arr[i].b = i * 100; }
  CHECK(arr[2].a == 0); CHECK(arr[2].b == 200); CHECK(arr[1].a == -1);
  return bad;
}
