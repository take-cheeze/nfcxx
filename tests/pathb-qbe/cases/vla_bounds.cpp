// Path B: the subscript of a variable-length array is bounds-checked against the run-time element count, like the subscript
// of a fixed array (traps/vla_index.cpp has the failing case). Valid programs are unaffected: every index in range, the
// address one past the end, a multi-dimensional VLA whose inner dimensions are constants (checked against count / row
// size), one whose inner dimension is a run-time value (not checked: the row size is not a constant), and a pointer
// derived from the array.
// EXPECT: 0
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

__attribute__((noinline)) int sum1(int n) {
  int v[n];
  for (int i = 0; i < n; ++i) v[i] = i + 1;
  int s = 0;
  for (int i = n - 1; i >= 0; --i) s += v[i];
  int *end = &v[n];       // one past the end is a valid address
  int *p = v;
  CHECK(end - p == n);
  CHECK(p[n - 1] == n);
  return s;
}

__attribute__((noinline)) int sum2(int n) {
  int m[n][3];
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < 3; ++j) m[i][j] = i * 3 + j;
  int s = 0;
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < 3; ++j) s += m[i][j];
  return s;
}

__attribute__((noinline)) int sum3(int n, int k) {
  int m[n][k];            // a run-time row size: the outer index is not checked
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < k; ++j) m[i][j] = i * k + j;
  int s = 0;
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < k; ++j) s += m[i][j];
  return s;
}

__attribute__((noinline)) long sumw(unsigned long n) {
  long w[n];
  for (unsigned long i = 0; i < n; ++i) w[i] = (long)i * 2;
  long s = 0;
  for (unsigned long i = 0; i < n; ++i) s += w[i];
  return s;
}

__attribute__((noinline)) int sum_char(unsigned char n) {
  unsigned char c[n];
  for (int i = 0; i < n; ++i) c[i] = (unsigned char)i;
  int s = 0;
  for (unsigned char i = 0; i < n; ++i) s += c[i];
  return s;
}

int main() {
  CHECK(sum1(5) == 15);
  CHECK(sum1(1) == 1);
  CHECK(sum2(4) == 66);
  CHECK(sum2(1) == 3);
  CHECK(sum3(3, 4) == 66);
  CHECK(sumw(10) == 90);
  CHECK(sum_char(5) == 10);
  return bad;
}
