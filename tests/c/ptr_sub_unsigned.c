/* EXPECT: 0 */
/* p - n and p -= n with an unsigned count narrower than 64 bits: the count is widened before it is negated. Path B
   negated it in its own type (p - (uint32_t)2 became p + 4294967294 elements): a crash in ASTro's baruby_precise
   (EVAL_node_call_builtin: `VALUE *args = sp - params_cnt;`). */
#include <stdint.h>
__attribute__((noinline)) long *back(long *sp, uint32_t n) { return sp - n; }
__attribute__((noinline)) long *fwd(long *sp, uint32_t n) { return sp + n; }
__attribute__((noinline)) long *backs(long *sp, int n) { return sp - n; }
__attribute__((noinline)) long *backu8(long *sp, unsigned char n) { return sp - n; }
__attribute__((noinline)) long *backu16(long *sp, unsigned short n) { return sp - n; }
__attribute__((noinline)) long *backul(long *sp, unsigned long n) { return sp - n; }
__attribute__((noinline)) long *backeq(long *sp, uint32_t n) { sp -= n; return sp; }
int main(void) {
  long a[8];
  long *e = a + 6;
  int bad = 0;
  bad += back(e, 2) != a + 4;
  bad += fwd(e, 2) != a + 8;
  bad += backs(e, 3) != a + 3;
  bad += backu8(e, 5) != a + 1;
  bad += backu16(e, 6) != a;
  bad += backul(e, 4) != a + 2;
  bad += backeq(e, 1) != a + 5;
  bad += back(e, 0) != e;
  return bad;
}
