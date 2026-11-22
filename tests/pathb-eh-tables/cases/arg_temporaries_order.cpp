// EXPECT: 0
// When an exception leaves a full expression, its temporaries are destroyed in the reverse order of their construction
// ([except.ctor]). EDG chains a full expression's temporaries (each with its flag) in the order they are built, and the
// pad destroys such a run backwards (be/nfcxx_ir_eh.h ir_eh_run). The order of evaluation of the arguments is the
// compiler's (gcc's is right to left), so the program checks the order itself rather than comparing with g++'s output.
// Lifetime-extended temporaries of conditional expressions (each a run of its own) and a local between them keep their
// reverse order too.
#include <cstdio>
static int built[64], nbuilt, gone[64], ngone;
struct T {
  int v;
  T(int v) : v(v) { built[nbuilt++] = v; }
  T(const T &o) : v(o.v + 1000) { built[nbuilt++] = v; }
  ~T() { gone[ngone++] = v; }
};
__attribute__((noinline)) int boom(int x) {
  if (x) throw x;
  return 0;
}
void take(T, T, int) {}
void take_ref(const T &, const T &, const T &, int) {}
T mk(const T &a, int) { return T(a.v * 100); }
volatile int c = 1;

static int check(const char *what) {
  int bad = nbuilt != ngone;
  for (int i = 0; !bad && i < nbuilt; i++)
    if (gone[i] != built[nbuilt - 1 - i]) bad = 1;
  std::printf("%s: %d built, %d destroyed%s\n", what, nbuilt, ngone, bad ? ", NOT in reverse order" : "");
  nbuilt = ngone = 0;
  return bad;
}

int main() {
  int fails = 0;
  try { take(T(1), T(2), boom(1)); } catch (int) {}
  fails += check("by value");
  try { take_ref(T(3), T(4), T(5), boom(1)); } catch (int) {}
  fails += check("by reference");
  try { T a(6); take(a, T(7), boom(1)); } catch (int) {}
  fails += check("a copy and a temporary");
  try { take_ref(T(8), mk(T(9), 0), T(10), boom(1)); } catch (int) {}
  fails += check("a nested call's temporaries");
  try {
    const T &a = c ? T(11) : T(12);
    const T &b = c ? T(13) : T(14);
    T d(15);
    const T &e = c ? T(16) : T(17);
    (void)a; (void)b; (void)e;
    take_ref(T(18), T(19), T(20), boom(1));
  } catch (int) {}
  fails += check("lifetime-extended temporaries, a local, then an argument list");
  take(T(21), T(22), boom(0));
  fails += check("no exception");
  return fails;
}
