// A local array, indexed through a pointer (no array bounds check applies): the escaping slot is registered.
// SAFE: out-of-bounds access
static int sum(const int *p, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += p[i];
  return s;
}
int main() {
  int a[4] = {1, 2, 3, 4};
  int b[4] = {5, 6, 7, 8};
  return sum(a, 5) + b[0];
}
