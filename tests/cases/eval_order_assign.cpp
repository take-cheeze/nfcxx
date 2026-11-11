// EXPECT: 0
// C++17: in `a = b` and `a op= b` the right operand is evaluated before the left one; in `a << b`, `a >> b` and
// `a[b]` the left one before the right one. The generated C leaves all of these unspecified. Each probe records the
// order the operands were evaluated in and compares it.
#include <cstdio>
#include <cstring>

static char tr[64]; static int trn;
static void T(char c) { tr[trn++] = c; tr[trn] = 0; }
static int bad;
static void chk(const char* name, const char* want) {
  if (strcmp(tr, want)) { printf("FAIL %s: got %s want %s\n", name, tr, want); bad++; }
  trn = 0; tr[0] = 0;
}

static int gv; static int arr[8]; static int* gp_;
static int& gi() { T('i'); return gv; }
static int* gp() { T('p'); return arr; }
static int ix() { T('x'); return 2; }
static int rv() { T('r'); return 1; }
static int sa() { T('s'); return 1; }

struct S { int k; };
static S gs0;
static S* gsp() { T('c'); return &gs0; }
static S& gsr() { T('C'); return gs0; }

// Overloaded: the same rules as the built-in operators ([over.match.oper]).
struct O {
  int v;
  O& operator=(int n) { v = n; return *this; }
  O& operator+=(int n) { v += n; return *this; }
  O& operator<<(int n) { v = v * 10 + n; return *this; }
  int& operator[](int n) { v = n; return gv; }
};
static O go;
static O& gor() { T('O'); return go; }

int main() {
  gi() = rv();                       chk("assign", "ri");
  gi() += rv();                      chk("+=", "ri");
  gi() <<= rv();                     chk("<<=", "ri");
  gi() -= rv();                      chk("-=", "ri");
  gp()[ix()] = rv();                 chk("a[i] = r", "rpx");
  gp()[ix()] += rv();                chk("a[i] += r", "rpx");
  *gp() = rv();                      chk("*p = r", "rp");
  gsp()->k = rv();                   chk("p->k = r", "rc");
  gsr().k += rv();                   chk("r.k += r", "rC");
  (void)gp()[ix()];                  chk("a[i]", "px");
  (void)(sa() << rv());              chk("<<", "sr");
  (void)(sa() >> rv());              chk(">>", "sr");
  (void)(sa(), rv());                chk(",", "sr");

  gor() = rv();                      chk("O =", "rO");
  gor() += rv();                     chk("O +=", "rO");
  gor() << rv();                     chk("O <<", "Or");
  (void)gor()[rv()];                 chk("O []", "Or");

  // the value read for op= is read after the right operand ran
  gv = 1; gv += (gv = 10, 5);        if (gv != 15) { printf("FAIL op= value %d\n", gv); bad++; }
  { int i = 0; int a[4] = {9, 9, 9, 9}; a[i++] = i; if (a[0] != 0 || i != 1) { printf("FAIL a[i++] = i: %d %d\n", a[0], i); bad++; } }
  { int i = 0; int a[4] = {0, 0, 0, 0}; int j = (i++, i) << i; if (j != 2) { printf("FAIL shift %d\n", j); bad++; } }

  printf("%d failures\n", bad);
  return bad;
}
