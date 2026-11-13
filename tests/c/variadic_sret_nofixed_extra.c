/* EXPECT: 0 */
// X86-ONLY-qbe: failed on the arm64 CI job's qbe backend (cproc, a call of a variadic function that returns a struct, with no variadic argument; wrong value, not investigated). The case is about Path B's x86-64 SSA route: (variadic N) counts the sret pointer.
/* A call of a variadic function that returns a struct and gets no variadic argument: Path B's (variadic N) counts the
   hidden result pointer, so N is one more than the named arguments the call has (the SSA emitter refused it: "variadic
   call with 6 named arguments but 5", ASTro's korb_raise in koruby_precise). */
#include <stdarg.h>
typedef struct { long a, b; } R;
typedef struct { long a, b, c; } Big;
__attribute__((noinline)) R two(int n, long x, ...) {
  va_list ap;
  R r;
  r.a = n + x;
  r.b = 0;
  va_start(ap, x);
  while (n-- > 0) r.b += va_arg(ap, long);
  va_end(ap);
  return r;
}
__attribute__((noinline)) Big three(int n, ...) {
  va_list ap;
  Big r;
  r.a = n;
  r.b = r.c = 0;
  va_start(ap, n);
  while (n-- > 0) r.b += va_arg(ap, int);
  va_end(ap);
  r.c = 7;
  return r;
}
int main(void) {
  int bad = 0;
  R r0 = two(0, 5);
  R r2 = two(2, 5, 10L, 20L);
  Big b0 = three(0);
  Big b3 = three(3, 1, 2, 3);
  bad += r0.a != 5 || r0.b != 0;
  bad += r2.a != 7 || r2.b != 30;
  bad += b0.a != 0 || b0.b != 0 || b0.c != 7;
  bad += b3.a != 3 || b3.b != 6 || b3.c != 7;
  return bad;
}
