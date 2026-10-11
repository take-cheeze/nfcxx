// EXPECT: 9
// Stack frames: a call's locals are released on return (1000 calls with 256 bytes of locals each would overflow the
// 128 KB memory otherwise). Also struct copies, and a return from inside a loop.
struct Big { int v[64]; };
int use(int k) {
  Big b;
  for (int i = 0; i < 64; i++) b.v[i] = k + i;
  return b.v[k & 63];
}
int find(int *p, int n, int x) {
  for (int i = 0; i < n; i++) {
    if (p[i] == x) return i;
  }
  return -1;
}
int main() {
  int total = 0;
  for (int i = 0; i < 1000; i++) total += use(i) & 1;
  int arr[5] = {4, 8, 15, 16, 23};
  total += find(arr, 5, 15) + find(arr, 5, 99) + 1;
  Big c;
  c.v[3] = 7;
  Big d = c;
  total += d.v[3];
  return total & 0xff;
}
