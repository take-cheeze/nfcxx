// CLEAN
// alloca in a loop: each pass allocates a new block (QBE does not reclaim it until the function returns), with its own
// redzones. Every block is written in bounds, and the blocks are 16-byte aligned. Sizes 1 to 300, not multiples of 8.
static long run(int rounds) {
  long sum = 0;
  for (int i = 0; i < rounds; i++) {
    int n = 1 + (i * 37) % 300;
    char *p = (char *)__builtin_alloca(n);
    if ((unsigned long)p % 16) return -1;
    for (int j = 0; j < n; j++) p[j] = (char)(j + i);
    sum += p[n - 1] + p[0];
  }
  return sum;
}
int main() {
  long s = run(400);
  return s > 0 ? 0 : 1;
}
