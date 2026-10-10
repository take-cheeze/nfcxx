// EXPECT: 0
// STDOUT: same
// __builtin_alloca: dynamic stack storage that lives until the function returns (not until the end of the block), also
// inside loops, next to variable-length arrays (which the front end lowers to heap blocks freed at scope exit) and across
// setjmp/longjmp, <alloca.h>'s alloca, and the _with_align forms.
#include <alloca.h>
#include <csetjmp>
#include <cstdint>
#include <cstdio>
#include <cstring>

static int simple(int n) {
  char *p = (char *)__builtin_alloca(n);
  memset(p, 7, n);
  int s = 0;
  for (int i = 0; i < n; i++) s += p[i];
  return s;
}

// every iteration allocates again; earlier blocks stay valid and distinct until return
static long loop(int n) {
  long s = 0;
  char *prev[64];
  for (int i = 1; i <= n; i++) {
    char *p = (char *)alloca(i * 8);
    for (int j = 0; j < i * 8; j++) p[j] = (char)i;
    prev[i - 1] = p;
  }
  for (int i = 1; i <= n; i++)
    for (int j = 0; j < i * 8; j++) s += prev[i - 1][j];
  return s;
}

static int overlaps(int n) {
  // blocks allocated in a loop do not overlap
  char *a[16];
  for (int i = 0; i < n; i++) a[i] = (char *)__builtin_alloca(24);
  for (int i = 0; i < n; i++)
    for (int j = i + 1; j < n; j++) {
      uintptr_t x = (uintptr_t)a[i], y = (uintptr_t)a[j];
      if (x < y + 24 && y < x + 24) return 1;
    }
  for (int i = 0; i < n; i++) if (((uintptr_t)a[i] & 15) != 0) return 2;
  return 0;
}

// alloca in a block that ends before the use
static int block_scope() {
  char *keep;
  {
    char *p = (char *)__builtin_alloca(32);
    strcpy(p, "still alive after the block");
    keep = p;
  }
  char *q = (char *)__builtin_alloca(32);   // must not reuse the first block
  strcpy(q, "second");
  return strcmp(keep, "still alive after the block") == 0 && strcmp(q, "second") == 0;
}

// next to a VLA (heap block released at scope exit) and a nested call that uses the stack
static int helper(int *p, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += p[i];
  return s;
}

static int with_vla(int n) {
  int vla[n];
  for (int i = 0; i < n; i++) vla[i] = i;
  int *a = (int *)__builtin_alloca(n * sizeof(int));
  for (int i = 0; i < n; i++) a[i] = 2 * vla[i];
  int s = helper(a, n);
  {
    int vla2[n + 1];
    for (int i = 0; i <= n; i++) vla2[i] = a[i % n];
    s += helper(vla2, n + 1);
  }
  int *b = (int *)__builtin_alloca(n * sizeof(int));
  memcpy(b, a, n * sizeof(int));
  return s + helper(b, n);
}

static int recurse(int n) {
  if (n == 0) return 0;
  int *p = (int *)__builtin_alloca(256 * sizeof(int));
  for (int i = 0; i < 256; i++) p[i] = n;
  return p[255] + recurse(n - 1) + p[0] - n;
}

// setjmp / longjmp with alloca on both sides of the jump
static jmp_buf jb;
static int jumper(int *p) {
  p[0] = 11;
  longjmp(jb, 3);
}

static int with_setjmp() {
  volatile int result = 0;
  char *before = (char *)__builtin_alloca(40);
  strcpy(before, "before");
  int *cell = (int *)__builtin_alloca(sizeof(int));
  int v = setjmp(jb);
  if (v == 0) {
    char *during = (char *)__builtin_alloca(40);
    strcpy(during, "during");
    result = jumper(cell);
  } else {
    char *after = (char *)__builtin_alloca(40);
    strcpy(after, "after");
    result = (strcmp(before, "before") == 0) + (*cell == 11) * 2 + (strcmp(after, "after") == 0) * 4 + (v == 3) * 8;
  }
  return result;
}

static int aligned() {
  void *p = __builtin_alloca_with_align(64, 256);   // 256 bits = 32 bytes
  void *q = __builtin_alloca_with_align_and_max(64, 128, 1024);
  void *big = __builtin_alloca_with_align(100, 4096 * 8);   // 4096 bytes
  return (((uintptr_t)p & 31) == 0) + (((uintptr_t)q & 15) == 0) * 2 + (((uintptr_t)big & 4095) == 0) * 4;
}

int main() {
  int r = 0;
  if (simple(10) != 70) r |= 1;
  if (simple(0) != 0) r |= 2;
  if (loop(40) != 177120) r |= 4;   // sum of i * 8 * i for i = 1..40
  if (overlaps(16) != 0) r |= 8;
  if (!block_scope()) r |= 16;
  if (with_vla(10) != 270) r |= 256;
  if (recurse(200) != 200 * 201 / 2) r |= 32;
  if (with_setjmp() != 15) r |= 64;
  if (aligned() != 7) r |= 128;
  printf("%d %ld %d %d %d\n", simple(10), loop(40), recurse(50), with_setjmp(), aligned());
  return r;
}
