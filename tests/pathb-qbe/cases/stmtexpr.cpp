// EXPECT: 0
// GNU statement expressions: the value of the last expression, locals declared inside, side effects in order,
// nesting, in conditions and loops, with control flow (break, continue, return, goto) leaving them, with a struct
// result and with a VLA inside. The exit code is the number of wrong results.
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)
#define MAX(a, b) ({ int _a = (a), _b = (b); _a > _b ? _a : _b; })

struct P { int x; int y; };

static int counter;
static int bump(int by) { counter += by; return counter; }

static int plain(int x) { return ({ int y = x + 1; y * 2; }); }

static int nested(int x) {
  return ({
    int a = x;
    int b = ({ int t = a * 3; t + 1; });
    a + b;
  });
}

static int in_loop(int n) {
  int s = 0;
  for (int i = 0; i < n; ++i) s += ({ int sq = i * i; sq % 3 == 0 ? sq : -1; });
  return s;
}

static int cond_loop(int n) {
  int i = 0, steps = 0;
  while (({ int next = i + 2; steps++; next <= n; })) i += 2;
  return i * 100 + steps;
}

static int brk(int n) {
  int s = 0;
  for (int i = 0; i < n; ++i) {
    s += ({ int r = i; if (i == 3) continue; if (i == 6) break; r; });
  }
  return s;
}

static int ret_inside(int x) {
  int r = ({ int t = x; if (t > 10) return 1000; t * 2; });
  return r + 1;
}

static int goto_out(int x) {
  int r = 0;
  r = ({ int t = x; if (t == 5) goto done; t + 100; });
  return r;
done:
  return -5;
}

static P make(int a, int b) { P p = {a, b}; return p; }

static int agg(int a) {
  P p = ({ P q = make(a, a + 1); q.x += 10; q; });
  return p.x * 100 + p.y;
}

static void v(int *p) { ({ *p += 5; }); }

static int vla(int n) {
  return ({ int a[n]; for (int i = 0; i < n; ++i) a[i] = i; int s = 0; for (int i = 0; i < n; ++i) s += a[i]; s; });
}

static int order() {
  counter = 0;
  int a = ({ bump(1); bump(10); bump(100); });
  int b = ({ bump(1000); });
  return (a == 111) + (b == 1111) * 2 + (counter == 1111) * 4;
}

static const char *str(int k) { return ({ const char *s = k ? "yes" : "no"; s; }); }

int main() {
  CHECK(plain(4) == 10);
  CHECK(nested(2) == 9);
  CHECK(MAX(3, 7) == 7);
  CHECK(MAX(-3, -7) == -3);
  CHECK(MAX(bump(1), bump(1)) == 2);
  CHECK(in_loop(7) == (0 + -1 + -1 + 9 + -1 + -1 + 36));
  CHECK(cond_loop(7) == 6 * 100 + 4);
  CHECK(brk(10) == 0 + 1 + 2 + 4 + 5);
  CHECK(ret_inside(4) == 9);
  CHECK(ret_inside(40) == 1000);
  CHECK(goto_out(5) == -5);
  CHECK(goto_out(6) == 106);
  CHECK(agg(3) == 1304);
  int z = 1;
  v(&z);
  CHECK(z == 6);
  CHECK(vla(5) == 10);
  CHECK(order() == 7);
  CHECK(str(1)[0] == 'y' && str(0)[0] == 'n');
  int w = ({ 5; });
  CHECK(w == 5);
  int u = ({ int t = 3; (void)t; 9; }) + ({ 1; });
  CHECK(u == 10);
  return bad;
}
