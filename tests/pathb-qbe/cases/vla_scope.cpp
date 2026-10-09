// EXPECT: 0
// Variable-length array storage is released at the end of its scope (the front end lowers a VLA to a __vla_alloc call
// at the declaration and a __vla_dealloc call on every exit from the scope: end of block, break, continue, goto,
// return, and the EH cleanup list). EDG's runtime counts the live allocations, which must be back to the starting
// value after each construct. The exit code is the number of wrong results.
extern "C" long __vla_number_of_active_allocations(void);

static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

static int sum(int n) {
  int a[n];
  for (int i = 0; i < n; ++i) a[i] = i;
  int s = 0;
  for (int i = 0; i < n; ++i) s += a[i];
  return s;
}

static int sequence(int n) {
  int total = 0;
  { int a[n]; a[0] = 1; total += a[0]; }
  { char b[n * 2]; b[1] = 2; total += b[1]; }
  { double c[n]; c[0] = 3; total += (int)c[0]; }
  return total;
}

static int nested(int n) {
  int a[n];
  a[0] = 1;
  {
    int b[n + 1];
    b[0] = 2;
    {
      int c[n + 2];
      c[0] = 3;
      CHECK(__vla_number_of_active_allocations() >= 3);
      a[0] += c[0];
    }
    a[0] += b[0];
  }
  return a[0];
}

static int loops(int n) {
  int s = 0;
  for (int i = 0; i < n; ++i) {
    int a[i + 1];
    a[0] = i;
    if (i == 1) continue;
    if (i == 5) break;
    s += a[0];
  }
  int k = 0;
  while (k < 3) {
    char buf[100 + k];
    buf[0] = (char)k;
    s += buf[0];
    ++k;
  }
  return s;
}

static int jumps(int n) {
  int s = 0;
  int again = 0;
top:
  {
    int a[n];
    a[0] = again;
    s += a[0];
    if (++again < 3) goto top;
    if (again == 3) goto out;
    s += 1000;
  }
out:
  return s;
}

static int early(int n) {
  int a[n];
  a[0] = 5;
  if (n > 1) {
    int b[n];
    b[0] = 6;
    return a[0] + b[0];
  }
  return a[0];
}

static int sw(int k, int n) {
  switch (k) {
    case 0: { int a[n]; a[0] = 1; return a[0]; }
    case 1: { int a[n]; a[0] = 2; break; }
    default: break;
  }
  return 7;
}

static int recur(int d) {
  int a[d + 1];
  a[0] = d;
  if (d == 0) return 0;
  return a[0] + recur(d - 1);
}

// Large blocks one after the other: with the storage released each time the peak stays at one block.
static long big(int rounds) {
  long s = 0;
  for (int r = 0; r < rounds; ++r) {
    char a[1 << 20];
    int n = 1 << 20;
    char v[n];
    v[0] = 1; v[n - 1] = 2;
    a[0] = 3;
    s += v[0] + v[n - 1] + a[0];
  }
  return s;
}

struct R { int *flag; ~R() { *flag += 1; } };
static int with_dtor(int n, int *flag) {
  R r = {flag};
  int a[n];
  a[0] = 4;
  return a[0];
}

int main() {
  long base = __vla_number_of_active_allocations();
  CHECK(sum(10) == 45);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(sequence(4) == 6);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(nested(3) == 6);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(loops(10) == 0 + 2 + 3 + 4 + 0 + 1 + 2);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(jumps(2) == 0 + 1 + 2);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(early(3) == 11 && early(1) == 5);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(sw(0, 2) == 1 && sw(1, 2) == 7 && sw(2, 2) == 7);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(recur(20) == 210);
  CHECK(__vla_number_of_active_allocations() == base);
  CHECK(big(50) == 50 * 6);
  CHECK(__vla_number_of_active_allocations() == base);
  int flag = 0;
  CHECK(with_dtor(3, &flag) == 4 && flag == 1);
  CHECK(__vla_number_of_active_allocations() == base);
  return bad;
}
