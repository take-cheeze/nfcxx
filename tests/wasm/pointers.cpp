// EXPECT: 100
// Address-of, pointer arithmetic, array indexing, struct members through pointers, pointer differences.
struct P { int x; int y; long z; };
int sum(int *p, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += p[i];
  return s;
}
int main() {
  int a[6] = {1, 2, 3, 4, 5, 6};
  int *p = a + 2;
  int d = (int)(&a[5] - p);
  P v = {10, 20, 30};
  P *pv = &v;
  pv->y += 5;
  long z = pv->z;
  char buf[4] = {7, 8, 9, 10};
  int t = buf[1] + buf[3];
  return (sum(a, 6) + *p + d + pv->y + (int)z + t) & 0xff;
}
