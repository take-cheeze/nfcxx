// EXPECT: 9
// Local arrays with constant initializers (a memcpy from a constant global), two-dimensional indexing, pointer
// arithmetic, and an array argument.
static int dot(const int *a, const int *b, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}
int main(void) {
  int v[5] = {1, 2, 3, 4, 5};
  int w[5] = {5, 4, 3, 2, 1};
  int m[2][3] = {{1, 2, 3}, {4, 5, 6}};
  int *p = v + 1;
  return dot(v, w, 5) + m[1][2] + p[1] - 35 + 0 * m[0][0];   /* 35 + 6 + 3 - 35 = 9 */
}
