// CLEAN
// A longjmp out of a C++ VLA's block skips its __vla_dealloc: the block is left behind, dead, and freed by the next
// __vla_alloc that finds its frame gone (lib/asan/nfcxx_vla_asan.c, free_dead). Nothing reads the abandoned block, so asan
// reports nothing; the values checked are the ones of the frames that are still live.
#include <cstdio>
#include <csetjmp>

static std::jmp_buf jb;

static void deep(int n) {
  int a[n];
  a[0] = 1;
  std::longjmp(jb, 1);
}

static int outer(int n) {
  int b[n];
  b[0] = 2;
  if (setjmp(jb) == 0) deep(n);
  int c[n + 1];   // the first allocation after the jump: the abandoned block of deep is freed here
  c[0] = 5;
  return b[0] + c[0];
}

int main() {
  int r = outer(3);
  std::printf("%d\n", r);
  return r == 7 ? 0 : 1;
}
