// EXPECT: 36
// A defined global array with an initializer, read in a loop, and a global written by the program (a zero-filled one).
int g[8] = {1, 2, 3, 4, 5, 6, 7, 8};
int h[4];
int main() {
  int s = 0;
  for (int i = 0; i < 8; i++) s += g[i];
  h[2] = s;
  h[1] = h[2] - 30;
  return h[1] + h[2] - 6;   // 6 + 36 - 6 = 36
}
