// EXPECT: 0
// Variable-length arrays (GNU extension in C++): dynamic stack storage, sizeof, indexing, two dimensions,
// pointers to VLA rows (pointer arithmetic with a run-time element size), loops that allocate again on every
// iteration (the storage must not grow with the iteration count), recursion, a backward goto, a VLA of structs.
// The exit code is the number of wrong results.
extern "C" void *memset(void *, int, unsigned long);

static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

struct Pair { int a; long b; };

__attribute__((noinline)) static int sum_vla(int n) {
  int buf[n];
  for (int i = 0; i < n; ++i) buf[i] = i * i;
  int s = 0;
  for (int i = 0; i < n; ++i) s += buf[i];
  return s;
}

__attribute__((noinline)) static int sizes(int n, int m) {
  int a[n];
  char c[m];
  double d[n][m];
  CHECK(sizeof(a) == (unsigned long)n * sizeof(int));
  CHECK(sizeof(c) == (unsigned long)m);
  CHECK(sizeof(d) == (unsigned long)n * m * sizeof(double));
  CHECK(sizeof(d[0]) == (unsigned long)m * sizeof(double));
  CHECK(sizeof(d[0][0]) == sizeof(double));
  CHECK(sizeof a / sizeof a[0] == (unsigned long)n);
  return (int)sizeof(d);
}

__attribute__((noinline)) static int grid(int n, int m) {
  int g[n][m];
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < m; ++j) g[i][j] = i * 100 + j;
  int s = 0;
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < m; ++j) s += g[i][j] - (i * 100 + j);
  CHECK(s == 0);
  CHECK(g[n - 1][m - 1] == (n - 1) * 100 + (m - 1));
  // pointer to a row of VLA type: p + 1 advances by m ints
  int (*row)[m] = g;
  CHECK((*row)[1] == 1);
  CHECK((*(row + 1))[0] == 100);
  CHECK(row[n - 1][m - 1] == (n - 1) * 100 + (m - 1));
  CHECK((row + n) - row == n);
  CHECK(sizeof(*row) == (unsigned long)m * sizeof(int));
  int (*p)[m] = &g[1];
  ++p;
  CHECK(p[0][2] == 202);
  p--;
  CHECK(p[0][2] == 102);
  return g[1][1];
}

__attribute__((noinline)) static long loop_alloc(int rounds) {
  long total = 0;
  for (int i = 1; i <= rounds; ++i) {
    // 4 KB .. 8 KB per iteration; without reuse 200000 iterations would need over a GB of stack
    int n = 1000 + (i % 1000);
    int buf[n];
    memset(buf, 0, sizeof(buf));
    buf[0] = i;
    buf[n - 1] = 1;
    total += buf[0] + buf[n - 1] + (long)sizeof(buf) / 4000;
  }
  return total;
}

__attribute__((noinline)) static int growing(int rounds) {
  int ok = 0;
  for (int n = 1; n <= rounds; ++n) {
    char b[n];
    b[0] = 1;
    b[n - 1] = 2;
    ok += b[0] + b[n - 1] - (n == 1 ? 1 : 0);
  }
  return ok;
}

__attribute__((noinline)) static int rec(int n) {
  int local[n + 1];
  local[0] = n;
  local[n] = n * 2;
  if (n == 0) return local[0];
  int r = rec(n - 1);
  CHECK(local[0] == n && local[n] == n * 2);
  return r + local[0];
}

__attribute__((noinline)) static int with_goto(int n) {
  int count = 0;
again:
  {
    long v[n + count];
    v[0] = count;
    v[n + count - 1] = 10;
    CHECK(v[0] == count && v[n + count - 1] == 10);
    count++;
    if (count < 5) goto again;
  }
  return count;
}

__attribute__((noinline)) static int structs(int n) {
  Pair ps[n];
  for (int i = 0; i < n; ++i) { ps[i].a = i; ps[i].b = -(long)i; }
  long s = 0;
  for (int i = 0; i < n; ++i) s += ps[i].a + ps[i].b * 2;
  CHECK(sizeof(ps) == n * sizeof(Pair));
  Pair *last = &ps[n - 1];
  CHECK(last - ps == n - 1);
  return (int)s;
}

__attribute__((noinline)) static int takes_ptr(int *p, int n) {
  int s = 0;
  for (int i = 0; i < n; ++i) s += p[i];
  return s;
}

__attribute__((noinline)) static int pass_vla(int n) {
  int v[n];
  for (int i = 0; i < n; ++i) v[i] = i + 1;
  return takes_ptr(v, n);
}

__attribute__((noinline)) static int in_switch(int k, int n) {
  switch (k) {
    case 0: {
      int a[n];
      a[0] = 11;
      return a[0];
    }
    case 1: {
      char a[n + 3];
      a[n + 2] = 22;
      return a[n + 2];
    }
    default: return -1;
  }
}

int main() {
  CHECK(sum_vla(1) == 0);
  CHECK(sum_vla(10) == 285);
  CHECK(sum_vla(100) == 328350);
  CHECK(sizes(3, 5) == 120);
  CHECK(sizes(1, 1) == 8);
  CHECK(grid(4, 6) == 101);
  CHECK(grid(3, 3) == 101);
  CHECK(loop_alloc(200000) == 200000L * 200001L / 2 + 2L * 200000L);
  CHECK(growing(300) == 300 * 3);
  CHECK(rec(10) == 55);
  CHECK(with_goto(3) == 5);
  CHECK(structs(6) == (0 + 1 + 2 + 3 + 4 + 5) * -1);
  CHECK(pass_vla(7) == 28);
  CHECK(in_switch(0, 4) == 11);
  CHECK(in_switch(1, 4) == 22);
  CHECK(in_switch(2, 4) == -1);
  return bad;
}
