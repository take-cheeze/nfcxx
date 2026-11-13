/* -ftrivial-auto-var-init=zero: an automatic variable without an initializer is zero from its declaration, padding
   included. Every read below is of an uninitialized local, after a call has left the stack dirty; the program exits 0
   when all of them are zero. Built with the option by tests/nfcc/run.sh (Path B against gcc with the same option; no VLA here: a VLA is not initialized, and Path B's VLA needs EDG's runtime to link); without
   the option the reads are indeterminate, so tests/c/run.sh does not take this directory. */
#include <string.h>

#define NOINLINE __attribute__((noinline))

/* leave 0xA5 bytes over the stack that the callees below use */
NOINLINE static void dirty(void)
{
  volatile unsigned char buf[2048];
  int i;
  for (i = 0; i < (int)sizeof buf; i++) buf[i] = 0xA5;
}

struct padded { char c; long l; short s; };            /* 7 bytes of padding before l, 6 after s */
struct nested { struct padded p; char tail[3]; double d; };
union both { char c; long long ll; double d; };

NOINLINE static int scalars(void)
{
  int i; long l; char c; short s; double d; float f; void *p; unsigned long long ull;
  if (i || l || c || s || d != 0.0 || f != 0.0f || p || ull) return 1;
  return 0;
}

NOINLINE static int arrays(void)
{
  int a[64]; char b[33]; double m[4][5];
  size_t k; int bad = 0;
  for (k = 0; k < 64; k++) bad |= a[k] != 0;
  for (k = 0; k < 33; k++) bad |= b[k] != 0;
  for (k = 0; k < 20; k++) bad |= ((double *)m)[k] != 0.0;
  return bad;
}

NOINLINE static int bytes_zero(const void *p, size_t n)
{
  const unsigned char *q = p;
  size_t k;
  for (k = 0; k < n; k++) if (q[k]) return 1;
  return 0;
}

NOINLINE static int structs(void)
{
  struct padded sp; struct nested sn; union both u;
  if (bytes_zero(&sp, sizeof sp)) return 1;    /* the padding bytes too */
  if (bytes_zero(&sn, sizeof sn)) return 1;
  if (bytes_zero(&u, sizeof u)) return 1;
  if (sp.c || sp.l || sp.s || sn.p.l || sn.tail[2] || sn.d != 0.0 || u.ll) return 1;
  return 0;
}

NOINLINE static int scopes(void)
{
  int outer;
  int bad = outer != 0;
  {
    char inner[16];
    int j;
    for (j = 0; j < 16; j++) bad |= inner[j] != 0;
    {
      long deep;
      bad |= deep != 0;
      deep = 99;                                  /* a store does not leak into the next declaration */
    }
    {
      long deep2;
      bad |= deep2 != 0;
    }
  }
  return bad;
}

NOINLINE static int loops(void)
{
  int bad = 0, i;
  for (i = 0; i < 5; i++) {
    int x;                                        /* zeroed again each time the declaration is reached */
    char buf[8];
    bad |= x != 0 || bytes_zero(buf, sizeof buf);
    x = 7 + i;
    memset(buf, 0x5A, sizeof buf);
  }
  i = 0;
  while (i < 3) {
    long y;
    bad |= y != 0;
    y = -1;
    i++;
  }
  for (int z; i < 4; i++) bad |= z != 0;          /* a declaration in a for header */
  return bad;
}

NOINLINE static int jumps(int n)
{
  int r = 0;
  switch (n) {
    case 0:
      ;
      int skipped;                                /* its declaration is jumped over for n == 1; the value is then indeterminate */
    case 1:
      skipped = 5;
      r = skipped;
      break;
  }
  return r;
}

NOINLINE static int opt_out(void)
{
  int u __attribute__((uninitialized));          /* left alone: only that it compiles and runs is checked */
  u = 3;
  return u != 3;
}

int main(void)
{
  int r;
  dirty(); if ((r = scalars())) return 10 + r;
  dirty(); if ((r = arrays())) return 20 + r;
  dirty(); if ((r = structs())) return 30 + r;
  dirty(); if ((r = scopes())) return 40 + r;
  dirty(); if ((r = loops())) return 50 + r;
  if (jumps(0) != 5 || jumps(1) != 5) return 60;
  if (opt_out()) return 70;
  return 0;
}
