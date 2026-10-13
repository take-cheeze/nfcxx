// CLEAN
// Frames reuse the same stack: each call's objects (with redzones on qbe) are unpoisoned when it returns, so the next
// call's objects at the same addresses are addressable. Objects whose size is not a multiple of 8 (5 and 12 bytes) use
// all their bytes.
#include <cstring>
static int fill(int n) {
  char b[5];
  int a[3];
  for (int i = 0; i < 5; i++) b[i] = (char)(i + n);
  for (int i = 0; i < 3; i++) a[i] = b[i] + i;
  return a[0] + a[1] + a[2] + b[4];
}
static int chain(int n) {
  int big[64];
  std::memset(big, 0, sizeof big);
  big[63] = n;
  return fill(n) + big[63];
}
int main() {
  int s = 0;
  for (int i = 0; i < 200; i++) s += chain(i) & 1;
  return s >= 0 ? 0 : 1;
}
