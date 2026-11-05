// Path B bit-fields: reads and writes of the storage unit, sign extension, truncation, read-modify-write,
// compound assignment and ++/-- on bit-fields, neighbours that must stay untouched, bit-fields next to other
// members, initialisation (local and static), arrays of structs, bit-fields through pointers and references to
// the struct. The exit code is the number of wrong results.
// EXPECT: 0
struct Mixed {
  char c;
  unsigned a : 3;
  int b : 5;
  unsigned long long d : 40;
  short s : 4;
  bool f : 1;
  unsigned u : 1;
  long long big : 33;
  int tail;
};

struct Packed2 {
  unsigned x : 4;
  unsigned y : 4;
  unsigned z : 8;
  unsigned w : 16;
};

struct Wide {
  unsigned lo : 32;
  unsigned hi : 32;
};

struct SChar {
  signed char p : 3;
  unsigned char q : 5;
  signed char r : 8;
};

enum Color { Red, Green, Blue, White };
struct WithEnum {
  Color col : 2;
  unsigned pad : 6;
  unsigned char tail;
};

static Mixed g_mixed = {7, 5, -3, 0x123456789ULL, -2, true, 1, -1, 99};
static Packed2 g_pack = {9, 10, 200, 60000};
static Packed2 g_zero;

static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

static int set_read(Mixed *m) {
  m->a = 9;      // truncates to 1
  m->b = 17;     // 10001 as 5 bits is -15
  m->d = 0xFFFFFFFFFFFULL;  // 44 bits, keeps the low 40
  m->s = 9;      // -7
  m->f = 2;      // bool: true
  m->big = 0x1FFFFFFFFLL;   // 33 bits all ones = -1
  return 0;
}

static int by_value(Mixed m) { return (int)m.a + m.b; }

static void ref_inc(Packed2 &p) { p.y++; p.x += 20; }

int main() {
  Mixed m;
  m.c = 'z';
  m.tail = 1234;
  m.a = 1;
  m.b = -1;
  m.d = 0;
  m.s = 0;
  m.f = false;
  m.u = 0;
  m.big = 0;

  // plain read and write, neighbours untouched
  m.a = 5;
  CHECK(m.a == 5);
  CHECK(m.b == -1);
  CHECK(m.c == 'z');
  CHECK(m.tail == 1234);
  m.b = -16;
  CHECK(m.b == -16);
  CHECK(m.a == 5);
  m.b = 15;
  CHECK(m.b == 15);
  CHECK(m.a == 5);

  // truncation and sign extension
  set_read(&m);
  CHECK(m.a == 1);
  CHECK(m.b == -15);
  CHECK(m.d == 0xFFFFFFFFFFULL);
  CHECK(m.s == -7);
  CHECK(m.f == true);
  CHECK(m.big == -1);
  CHECK(m.c == 'z');
  CHECK(m.tail == 1234);
  CHECK(m.u == 0);

  // assignment as an expression: the value is the stored (truncated) one
  int v = (m.a = 14);          // 14 & 7 = 6
  CHECK(v == 6);
  int w = (m.b = 31);          // 31 as 5 bits is -1
  CHECK(w == -1);
  CHECK(m.b == -1);
  unsigned long long dv = (m.d = 0x1FFFFFFFFFFULL);
  CHECK(dv == 0xFFFFFFFFFFULL);

  // compound assignment
  m.a = 3;
  m.a += 6;                    // 9 -> 1
  CHECK(m.a == 1);
  m.a -= 2;                    // -1 -> 7
  CHECK(m.a == 7);
  m.a *= 3;                    // 21 -> 5
  CHECK(m.a == 5);
  m.a <<= 1;                   // 10 -> 2
  CHECK(m.a == 2);
  m.a |= 4;
  CHECK(m.a == 6);
  m.a &= 3;
  CHECK(m.a == 2);
  m.a ^= 7;
  CHECK(m.a == 5);
  m.a >>= 1;
  CHECK(m.a == 2);
  m.b = 7;
  m.b += 10;                   // 17 -> -15
  CHECK(m.b == -15);
  m.b >>= 2;                   // arithmetic shift of -15
  CHECK(m.b == -4);
  m.b /= 3;
  CHECK(m.b == -1);
  m.s = -8;
  m.s -= 1;                    // -9 -> 7
  CHECK(m.s == 7);
  CHECK(m.d == 0xFFFFFFFFFFULL);
  m.d += 2;                    // wraps at 40 bits
  CHECK(m.d == 1);
  m.big = 0xFFFFFFFFLL;
  m.big += 1;                  // 0x100000000 is bit 32, the sign bit of a 33-bit field: -2^32
  CHECK(m.big == -0x100000000LL);
  m.big += 0xFFFFFFFFLL;       // 0x1FFFFFFFF = -1
  CHECK(m.big == -1);

  // ++ and -- (pre and post), with the value used
  m.a = 7;
  unsigned o = m.a++;
  CHECK(o == 7);
  CHECK(m.a == 0);
  o = --m.a;
  CHECK(o == 7);
  CHECK(m.a == 7);
  m.b = 15;
  int ob = m.b++;
  CHECK(ob == 15);
  CHECK(m.b == -16);
  ob = ++m.b;
  CHECK(ob == -15);
  m.b--;
  --m.b;
  CHECK(m.b == -17 + 32);
  m.f = true;
  m.u = 1;
  m.u++;                       // 2 -> 0
  CHECK(m.u == 0);
  CHECK(m.f == true);
  m.tail = 0;
  CHECK(m.c == 'z');

  // expressions mixing fields
  m.a = 3;
  m.b = -2;
  m.s = 5;
  CHECK(m.a + m.b == 1);
  CHECK(m.a * m.s == 15);
  CHECK((m.a << 2) == 12);
  CHECK((int)(m.b < m.a) == 1);
  CHECK(m.b * m.b == 4);
  CHECK(!m.u);
  CHECK(by_value(m) == 1);

  // the static object with an initialiser
  CHECK(g_mixed.c == 7);
  CHECK(g_mixed.a == 5);
  CHECK(g_mixed.b == -3);
  CHECK(g_mixed.d == 0x123456789ULL);
  CHECK(g_mixed.s == -2);
  CHECK(g_mixed.f == true);
  CHECK(g_mixed.u == 1);
  CHECK(g_mixed.big == -1);
  CHECK(g_mixed.tail == 99);
  g_mixed.a += 3;
  CHECK(g_mixed.a == 0);
  CHECK(g_mixed.b == -3);

  CHECK(g_pack.x == 9);
  CHECK(g_pack.y == 10);
  CHECK(g_pack.z == 200);
  CHECK(g_pack.w == 60000);
  CHECK(g_zero.x == 0 && g_zero.y == 0 && g_zero.z == 0 && g_zero.w == 0);

  // local aggregate initialisation
  Packed2 p = {3, 12, 255, 1};
  CHECK(p.x == 3 && p.y == 12 && p.z == 255 && p.w == 1);
  Packed2 p2 = {1};
  CHECK(p2.x == 1 && p2.y == 0 && p2.z == 0 && p2.w == 0);
  Mixed lm = {1, 2, -4, 5, 3, false, 0, 1000000, 8};
  CHECK(lm.a == 2 && lm.b == -4 && lm.d == 5 && lm.s == 3 && lm.f == false && lm.big == 1000000 && lm.tail == 8);

  // through a reference and copies
  ref_inc(p);
  CHECK(p.y == 13);
  CHECK(p.x == 7);             // 3 + 20 = 23 -> 7
  CHECK(p.z == 255);
  Packed2 q = p;               // whole-struct copy keeps the bits
  CHECK(q.x == 7 && q.y == 13 && q.z == 255 && q.w == 1);
  q.w = 0xABCD;
  CHECK(p.w == 1);
  CHECK(q.w == 0xABCD);

  // a field that is the whole unit
  Wide wd;
  wd.lo = 0xFFFFFFFFu;
  wd.hi = 0x80000000u;
  CHECK(wd.lo == 0xFFFFFFFFu);
  CHECK(wd.hi == 0x80000000u);
  wd.lo += 1;
  CHECK(wd.lo == 0);
  CHECK(wd.hi == 0x80000000u);
  wd.hi = wd.lo - 1;
  CHECK(wd.hi == 0xFFFFFFFFu);

  // narrow declared types
  SChar sc;
  sc.p = 3;
  sc.q = 31;
  sc.r = -128;
  CHECK(sc.p == 3);
  CHECK(sc.q == 31);
  CHECK(sc.r == -128);
  sc.p = 4;                    // -4
  CHECK(sc.p == -4);
  CHECK(sc.q == 31);
  sc.q += 2;                   // 33 -> 1
  CHECK(sc.q == 1);
  sc.r += 128;
  CHECK(sc.r == 0);
  sc.r = 127;
  sc.r++;                      // wraps to -128
  CHECK(sc.r == -128);
  CHECK(sc.p == -4);

  // enum and an array of structs
  WithEnum we;
  we.tail = 77;
  we.pad = 0;
  we.col = Blue;
  CHECK(we.col == Blue);
  we.col = White;
  CHECK(we.col == White);
  CHECK(we.pad == 0);
  CHECK(we.tail == 77);
  Packed2 arr[4];
  for (int i = 0; i < 4; ++i) {
    arr[i].x = i;
    arr[i].y = 15 - i;
    arr[i].z = i * 60;
    arr[i].w = i * 1000;
  }
  int sum = 0;
  for (int i = 0; i < 4; ++i) sum += arr[i].x + arr[i].y + arr[i].z + arr[i].w;
  CHECK(sum == (0 + 1 + 2 + 3) + (15 + 14 + 13 + 12) + (0 + 60 + 120 + 180) + (0 + 1000 + 2000 + 3000));

  // in a condition and in a loop
  Packed2 cnt;
  cnt.x = 0;
  cnt.y = 5;
  int iters = 0;
  while (cnt.x != 9) { cnt.x++; cnt.y--; iters++; }
  CHECK(iters == 9);
  CHECK(cnt.y == (unsigned)(5 - 9) % 16);

  return bad;
}
