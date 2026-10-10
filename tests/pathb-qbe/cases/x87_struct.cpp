// Path B: a struct of 16 bytes whose only member is a long double is class X87 in the System V ABI: passed in memory, returned
// in st(0). The struct is a parameter and a result of ordinary, static and external functions, nested, in a function pointer
// call and in an array; the calls must give what the gcc backend gives. The IR golden is tests/pathb-ir/x87_struct.ir.
// EXPECT: 0
// The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

struct W { long double x; };
struct Wn { W in; };
struct Big { long double x, y; };     // 32 bytes: memory class as before

static W mk(long double v) { W w; w.x = v; return w; }
static long double sum(W a, int k, W b) { return a.x * k + b.x; }
W twice(W a) { W r; r.x = a.x * 2; return r; }
Wn wrap(W w) { Wn n; n.in = w; return n; }
static long double many(int a, int b, int c, int d, int e, int f, W w, long double x, W v) {
  return a + b + c + d + e + f + w.x + x + v.x;
}
Big big(long double v) { Big b; b.x = v; b.y = v + 1; return b; }

int main() {
  CHECK(mk(1.5L).x == 1.5L);
  CHECK(sum(mk(2), 3, mk(0.5L)) == 6.5L);
  CHECK(twice(mk(3)).x == 6.0L);
  CHECK(wrap(mk(4)).in.x == 4.0L);
  Wn n = wrap(twice(mk(1.25L)));
  CHECK(n.in.x == 2.5L);
  CHECK(many(1, 2, 3, 4, 5, 6, mk(0.5L), 0.25L, mk(8)) == 1 + 2 + 3 + 4 + 5 + 6 + 0.5L + 0.25L + 8.0L);
  // through function pointers
  W (*fp)(long double) = mk;
  CHECK(fp(2.5L).x == 2.5L);
  W (*tp)(W) = twice;
  CHECK(tp(mk(1)).x == 2.0L);
  // an array of them, copied and summed
  W arr[3];
  for (int i = 0; i < 3; i++) arr[i] = mk(i + 0.5L);
  long double s = 0;
  for (int i = 0; i < 3; i++) s += twice(arr[i]).x;
  CHECK(s == 9.0L);
  // a 32-byte struct of two long doubles is unaffected
  CHECK(big(1.0L).y == 2.0L);
  return bad;
}
