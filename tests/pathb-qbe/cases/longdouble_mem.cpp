// long double in memory (docs/notes/pathb-longdouble.md): globals with static initializers, arrays, members of classes
// (the layout is EDG's: 16 bytes, 16-aligned), classes passed and returned by value, unions, static locals,
// references and pointers, new[], containers, default member initializers, lambdas, templates, constexpr values.
// EXPECT: 0
// STDOUT: same
#include <cstdio>
#include <cstddef>
#include <cstring>
#include <vector>
#include <map>
#include <algorithm>
#include <memory>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

long double g1 = 1.0L / 3;
long double g2 = -2.5e-3000L;
const long double kHalf = 0.5L;
static long double garr[3] = {1.5L, 2.5L};            // the third element is zero
long double gzero;
struct P { char c; long double v; int n; };            // v at offset 16, size 48
struct Q { long double a, b; };                        // 32 bytes: returned and passed in memory
struct R { int i; long double x = 7.5L; double d = 0.25; };
union U { long double ld; unsigned long w[2]; };
struct Big { long double v[4]; };
static P gp = {'x', 2.25L, 9};
static Q gq = {1.25L, -3.5L};
constexpr long double kConst = 1.0L / 4;
static_assert(kConst == 0.25L);
static_assert(sizeof(P) == 48 && offsetof(P, v) == 16 && sizeof(Q) == 32 && sizeof(R) == 48);

Q makeQ(long double a, long double b) { return Q{a + b, a - b}; }
long double sumQ(Q q) { return q.a + q.b; }
Q swapQ(Q q) { return Q{q.b, q.a}; }
Big makeBig() { Big b; for (int i = 0; i < 4; i++) b.v[i] = i * 0.5L; return b; }
long double sumBig(const Big& b) { long double s = 0; for (long double e : b.v) s += e; return s; }
long double& pick(long double* a, int i) { return a[i]; }
long double counter() { static long double c = 0.5L; c += 1; return c; }

template <class T> struct Box { T val; Box(T v) : val(v) {} T get() const { return val; } };

int main() {
  CHECK(g1 * 3 == 1.0L && g2 < 0 && g2 > -1e-2999L && kHalf == 0.5L);
  CHECK(garr[0] == 1.5L && garr[1] == 2.5L && garr[2] == 0 && gzero == 0);
  CHECK(gp.c == 'x' && gp.v == 2.25L && gp.n == 9 && gq.a == 1.25L && gq.b == -3.5L);
  gp.v *= 2; garr[2] = garr[0] + garr[1];
  CHECK(gp.v == 4.5L && garr[2] == 4.0L);

  Q q = makeQ(5, 3);
  CHECK(q.a == 8 && q.b == 2 && sumQ(q) == 10 && swapQ(q).a == 2 && sumQ(makeQ(1, 1)) == 2);
  Q q2 = q; q2.a = 100; q = q2;
  CHECK(q.a == 100 && q2.b == 2);
  Big bg = makeBig();
  CHECK(sumBig(bg) == 3.0L && makeBig().v[3] == 1.5L);

  R r{4};
  CHECK(r.x == 7.5L && r.d == 0.25 && r.i == 4);
  R* heap = new R{1, 9.5L, 1.5};
  CHECK(heap->x == 9.5L);
  delete heap;

  U u; u.ld = 1.0L;
  CHECK(u.w[0] == 0x8000000000000000UL && (u.w[1] & 0xffff) == 0x3fff);
  u.w[0] = 0xc000000000000000UL; u.w[1] = 0x3fff;
  CHECK(u.ld == 1.5L);

  long double loc[5];
  for (int i = 0; i < 5; i++) loc[i] = i * 1.25L;
  long double& ref = pick(loc, 3);
  ref = 99;
  const long double* cp = &loc[2];
  CHECK(loc[3] == 99 && *cp == 2.5L && cp[1] == 99 && &loc[4] - &loc[0] == 4);
  long double* hp = new long double[3]{1.0L, 2.0L, 3.0L};
  hp[1] += hp[2];
  CHECK(hp[1] == 5.0L);
  std::swap(hp[0], hp[2]);
  CHECK(hp[0] == 3.0L && hp[2] == 1.0L);
  delete[] hp;

  CHECK(counter() == 1.5L && counter() == 2.5L && counter() == 3.5L);

  std::vector<long double> v;
  for (int i = 0; i < 10; i++) v.push_back(1.0L / (i + 1));
  std::sort(v.begin(), v.end());
  CHECK(v.front() == 0.1L && v.back() == 1.0L && v.size() == 10);
  long double total = 0;
  for (long double e : v) total += e;
  printf("%La\n", total);
  std::map<long double, int> m;
  m[2.5L] = 1; m[-1.5L] = 2; m[1e400L] = 3;
  CHECK(m.begin()->first == -1.5L && m.rbegin()->first == 1e400L && m.at(2.5L) == 1);

  long double cap = 6.5L;
  auto lam = [cap](long double a) { return a * cap; };
  auto lam2 = [&cap](long double a) { cap += a; return cap; };
  CHECK(lam(2) == 13.0L && lam2(1) == 7.5L && lam(2) == 13.0L);

  Box<long double> bx(0.75L);
  CHECK(bx.get() == 0.75L && Box<long double>(bx).val == 0.75L);
  std::unique_ptr<long double> up(new long double(8.5L));
  CHECK(*up == 8.5L);
  P pp = gp; pp.v += 1;
  CHECK(pp.v == 5.5L && gp.v == 4.5L && pp.n == 9);
  CHECK(std::memcmp(&gq, &gq, sizeof gq) == 0);
  printf("%La %La %La\n", g1, gp.v, kConst);
  printf("%d\n", fails);
  return fails;
}
