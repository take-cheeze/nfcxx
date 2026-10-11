// EXPECT: 79
// A global of 80 KB: the memory grows past two pages so that the stack keeps 64 KB of room above the data. The
// calls after the data is set check that the stack still works above it.
int big[20000];
int tail[4] = {1, 2, 3, 4};
int sum(int *p, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += p[i];
  return s;
}
int main() {
  big[19999] = 40;
  big[0] = 5;
  int local[3] = {7, 8, 9};
  return (sum(local, 3) + big[19999] + big[0] + sum(tail, 4)) & 255;   // 24 + 40 + 5 + 10 = 79
}
