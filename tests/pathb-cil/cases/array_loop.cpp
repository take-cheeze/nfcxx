// EXPECT: 140
// An array indexed in a loop: the sum of i*i for i in 0..7 is 140. A global array and a local one each use index.
static int g[8];
int main(void) {
  int l[8];
  for (int i = 0; i < 8; i++) { g[i] = i * i; l[i] = g[i]; }
  int s = 0;
  for (int i = 0; i < 8; i++) s += l[i];
  return s;
}
