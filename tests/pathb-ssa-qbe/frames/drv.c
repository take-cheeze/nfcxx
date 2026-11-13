#include <stdio.h>

void fill(int *p, int n, int v) { for (int i = 0; i < n; i++) p[i] = v + i; }
int sumi(int *p, int n) { int s = 0; for (int i = 0; i < n; i++) s += p[i]; return s; }

int case_main(int);

/* the sum of fill(256 ints, v) */
static int sm(int v) { return 256 * v + 32640; }

int main(void) {
  int ns[] = {0, 1, -5, 100};
  for (int k = 0; k < 4; k++) {
    int n = ns[k];
    /* g n+7 (summed last), a n, b n+1, c n+2 and d n+3, f n+4, e in the loop n, n+1, n+2 */
    int want = sm(n) + sm(n + 1) + sm(n + 2) + sm(n + 3) + sm(n + 4) + sm(n) + sm(n + 1) + sm(n + 2) + sm(n + 7);
    int got = case_main(n);
    if (got != want) { printf("n=%d: got %d, want %d\n", n, got, want); return 1; }
  }
  printf("ok\n");
  return 0;
}
