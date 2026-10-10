// EXPECT: 0
// C++17 evaluation order of the operands of overloaded and built-in operators, member calls, calls through a
// function pointer and `new`. The program counts the probes whose order was wrong; the gcc backend (generated C,
// where EDG has to sequence the operands explicitly) and Path B (the IR) must both give 0. docs/notes/eval-order.md.
static char tr[64]; static int trn;                  // the order the probes ran in
static void T(char c) { tr[trn++] = c; tr[trn] = 0; }
static int bad;
static bool same(const char* a, const char* b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static void chk(const char* want) { if (!same(tr, want)) bad++; trn = 0; tr[0] = 0; }

static int x;                                        // written by f and g, read by the right operands
static int f() { x = 7; T('f'); return 1; }
static int g() { x += 1; T('g'); return 2; }
static int a() { T('a'); return 1; }
static int b() { T('b'); return 2; }

static char lg[64]; static int lgn;                  // the values a stream received
static void put(int v) { lg[lgn++] = (char)('0' + v); lg[lgn] = 0; }
struct Out {
  Out& operator<<(int v) { put(v); return *this; }
  Out& operator>>(int v) { put(v); return *this; }
  Out& m(int p, int q) { put(p); put(q); return *this; }
  int& operator[](int i) { put(i); return x; }
};
struct Fo { Fo& operator()(int) { return *this; } };
static Out out;
static Out& getout() { T('o'); return out; }
static Fo fo;
static Fo& getfo() { T('F'); return fo; }
static void clear_log() { lgn = 0; lg[0] = 0; }

static int gv; static int arr[8];
static int& gi() { T('i'); return gv; }
static int* gp() { T('p'); return arr; }
static int ix() { T('x'); return 2; }
static int rv() { T('r'); return 1; }

typedef int (*fn_t)(int);
static int id(int v) { T('I'); return v; }
static fn_t getfn() { T('g'); return id; }

static char buf[64];
void* operator new(unsigned long, int) { T('W'); return buf; }
static int nw() { T('V'); return 1; }
struct Q { int v; Q(int p) : v(p) { T('Q'); } };

int main() {
  x = 0; clear_log();
  getout() << f() << x;                chk("of");      if (!same(lg, "17")) bad++;
  x = 0; clear_log();
  getout() << x << f() << x << g() << x;  chk("ofg");  if (!same(lg, "01728")) bad++;
  x = 0; clear_log();
  getout() >> x >> f() >> x;           chk("of");      if (!same(lg, "017")) bad++;
  x = 0; clear_log();
  getout().m(x, f());                  chk("of");      if (!same(lg, "01")) bad++;
  clear_log();
  getout().m(a(), x);                  chk("oa");
  getfo()(a())(b());                   chk("Fab");
  (void)getfn()(a());                  chk("gaI");
  (void)getfn()(a() + x);              chk("gaI");
  gi() = rv();                         chk("ri");
  gi() += rv();                        chk("ri");
  *gp() = rv();                        chk("rp");
  gp()[ix()] = rv();                   chk("rpx");
  gp()[ix()] -= rv();                  chk("rpx");
  (void)gp()[ix()];                    chk("px");
  clear_log();
  (void)getout()[a()];                 chk("oa");      if (!same(lg, "1")) bad++;

  gv = 1; gv += (gv = 10, 5);          if (gv != 15) bad++;
  { int i = 0; int t[4] = {9, 9, 9, 9}; t[i++] = i; if (t[0] != 0 || i != 1) bad++; }
  { int i = 0; int j = (i++, i) << i; if (j != 2) bad++; }

  // new: the allocation function call (with its placement arguments) comes before the constructor arguments
  Q* q = new (nw()) Q(a());            chk("VWaQ");
  if (q->v != 1) bad++;
  return bad;
}
