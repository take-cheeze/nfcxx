// CLEAN
// A compound literal lives as long as the block that holds it. Every access here is inside that block, so nothing is
// reported: a literal used in its block, made again on each pass of a loop, passed to a function, its address taken and
// used, in a switch and around a goto, and a pointer to one that an enclosing block reads while the block is still open.
struct P { int x, y; };

static int sum(const int *a, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i];
  return s;
}
static int px(const P *p) { return p->x + p->y; }

static int in_block(int n) {
  int *p = (int[]){n, n + 1, n + 2};
  int r = p[0] + p[2];
  {
    int *q = (int[]){r, 2 * r};
    r += q[1];
  }
  return r + p[1];
}

static int in_loop(int n) {
  int total = 0;
  for (int i = 0; i < n; i++) {
    int *a = (int[]){i, i + 1, n};
    total += sum(a, 3);
    P *p = &(P){i, n};
    p->x += 1;
    total += px(p);
  }
  int k = 0;
  while (k < 3) {
    const int *b = (int[]){k, k * 2};
    total += b[1];
    k++;
  }
  return total;
}

static int by_call(int n) {
  int r = sum((int[]){n, 1, 2, 3}, 4);
  r += px(&(P){n, 5});
  r += sum((int[]){1, 2}, 2) + sum((int[]){3, 4}, 2);
  return r;
}

static int in_switch(int n) {
  int r = 0;
  switch (n) {
  case 0: {
    int *a = (int[]){n, 7};
    r = a[1];
    break;
  }
  case 1:
    r = sum((int[]){n, 8}, 2);
    // fall through
  default: {
    P *p = &(P){n, 9};
    r += p->y;
  }
  }
  return r;
}

static int with_goto(int n) {
  int r = 0, tries = 0;
again:
  {
    int *a = (int[]){n, tries, 4};
    r += a[0] + a[1] + a[2];
    if (++tries < 3) goto again;
  }
  for (int i = 0; i < n; i++) {
    int *b = (int[]){i, 5};
    if (b[0] > 2) goto done;
    r += b[1];
  }
done:
  return r;
}

static int outer_pointer(int n) {
  int *keep;
  int r = 0;
  {
    keep = (int[]){n, n * 2};
    r += keep[1];
    {
      int *inner = (int[]){keep[0], 3};
      r += inner[0] + inner[1] + keep[0];
    }
    r += keep[0];
  }
  return r;
}

static int cond_literal(int n) {
  int r = 0;
  int *p = n > 2 ? (int[]){n, 1} : (int[]){2, n};
  r += p[0] + p[1];
  return r;
}

int main() {
  int r = 0;
  for (int i = 0; i < 4; i++) {
    r += in_block(i) + in_loop(i) + by_call(i) + in_switch(i % 3) + with_goto(i) + outer_pointer(i) + cond_literal(i);
  }
  return r == 0 ? 1 : 0;
}
