// EXPECT: 0
// STDOUT: same
// Callees with landing pads inlined into callers (scripts/pathb-ir-opt.rb, eh_inline): cleanups of the inlined copy
// that hand the exception on to the caller's pad, two copies in one caller, a copy inside a copy, a catch inside an
// inlined callee that rethrows, and destructors with pads of their own inlined into a pad's code.
#include <stdio.h>
static char log_[256]; static int nl;
static void ev(char c) { log_[nl++] = c; }
static int boom;
static void maybe(int k) { if (k == boom) throw k; }
struct G { char c; G(char x) : c(x) { ev(c); } ~G() { ev(c - 'a' + 'A'); } };
struct H { char c; H(char x) : c(x) {} ~H() { G g('z'); ev(c); } };   // a destructor whose body has a cleanup
static inline void leaf(int k) { G a('a'); maybe(k); G b('b'); maybe(k + 1); }
static inline void twice(int k) { G c('c'); leaf(k); leaf(k + 10); }
static inline int catcher(int k) { try { G d('d'); twice(k); } catch (int e) { ev('!'); if (e > 20) throw; return e; } return 0; }
static int outer(int k) { H h('h'); G e('e'); return catcher(k); }
int main() {
  int ks[] = {0, 1, 2, 11, 12, 21, 22, 99};
  for (int i = 0; i < 8; i++) {
    nl = 0; boom = ks[i];
    int r = -1;
    try { r = outer(boom == 99 ? 50 : 0); } catch (int e) { ev('#'); r = 1000 + e; }
    log_[nl] = 0;
    printf("boom=%d r=%d %s\n", boom, r, log_);
  }
  return 0;
}
