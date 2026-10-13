// EXPECT: 100
// Clean under the ASan mode: in-bounds accesses to the stack objects of several sizes (the last byte of an odd-sized
// array included), to the statics, and to a struct copy; and two calls whose frames reuse the same stack, so the
// shadow of a returned frame is written again.
struct S {
  int a;
  char b;
  long c;
};

int g[3] = {1, 2, 3};
char gc[5] = {1, 2, 3, 4, 5};

int sum_chars(char* p, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += p[i];
  return s;
}

int f(int k) {
  char buf[5];
  for (int i = 0; i < 5; i++) buf[i] = (char)(i + k);
  int arr[3];
  arr[0] = k;
  arr[1] = k * 2;
  arr[2] = k * 3;
  int* q = arr;
  return sum_chars(buf, 5) + q[2];
}

int main() {
  S s1;
  s1.a = 4;
  s1.b = 'x';
  s1.c = 1000;
  S s2 = s1;
  int a[4];
  int* p = a;
  for (int i = 0; i < 4; i++) p[i] = i * i;
  char odd[7];
  odd[6] = 9;
  return f(2) + f(3) + s2.a + (s2.b - 'x') + (int)(s2.c / 100) + p[3] + g[2] + gc[4] + odd[6];
}
