// EXPECT: 0
// C++17 fixes the order of evaluation of these (the generated C leaves it unspecified): the object expression of a
// member call, the function expression of a call, and the operands of << and >> (also overloaded), before the
// arguments / the right operand. Each probe records the order the operands were evaluated in and compares it.
#include <cstdio>
#include <cstring>
#include <string>
#include <sstream>

static char tr[64]; static int trn;
static void T(char c) { tr[trn++] = c; tr[trn] = 0; }
static int bad;
static void chk(const char* name, const char* want) {
  if (strcmp(tr, want)) { printf("FAIL %s: got %s want %s\n", name, tr, want); bad++; }
  trn = 0; tr[0] = 0;
}

static int x;                                  // read by the right-hand operands, written by the left ones
static int f() { x = 7; T('f'); return 1; }
static int g() { x += 1; T('g'); return 2; }

struct OS { std::string s; };                  // free operator<<
static OS& operator<<(OS& o, int v) { o.s += std::to_string(v) + ","; return o; }
struct MS {                                    // member operator<< and >>
  std::string s;
  MS& operator<<(int v) { s += std::to_string(v) + ","; return *this; }
  MS& operator>>(int v) { s += std::to_string(v) + ";"; return *this; }
  MS& m(int a, int b) { s += std::to_string(a) + "+" + std::to_string(b) + ","; return *this; }
  int& operator[](int i) { s += std::to_string(i) + "]"; return x; }
};
static void expect(const char* n, const std::string& got, const char* want) {
  if (got != want) { printf("FAIL %s: got %s want %s\n", n, got.c_str(), want); bad++; }
}

static MS gm;
static MS& obj() { T('o'); return gm; }
static int a1() { T('a'); return 1; }

typedef int (*fn_t)(int);
static int id(int v) { T('i'); return v; }
static fn_t getfn() { T('g'); return id; }

struct C { int k; int m(int a, int b) { T('m'); return a + b; } virtual int v(int a, int b) { T('v'); return a - b; } };
struct D : C { int v(int a, int b) override { T('w'); return a * b; } };
static D gd;
static C* getc_() { T('c'); return &gd; }
static C& getr() { T('r'); return gd; }

int main() {
  { OS o; x = 0; o << f() << x;                    expect("free <<", o.s, "1,7,"); }
  { OS o; x = 0; o << x << f() << x << g() << x;   expect("free << chain", o.s, "0,1,7,2,8,"); }
  { MS o; x = 0; o << f() << x;                    expect("member <<", o.s, "1,7,"); }
  { MS o; x = 0; o << x << f() << x << g() << x;   expect("member << chain", o.s, "0,1,7,2,8,"); }
  { MS o; x = 0; o >> x >> f() >> x;               expect("member >>", o.s, "0;1;7;"); }
  { std::ostringstream o; x = 0; o << x << f() << x << g() << x; expect("ostringstream", o.str(), "01728"); }
  { std::ostringstream o; x = 0; o << f() << x;    expect("ostringstream 2", o.str(), "17"); }
  { std::ostringstream o; x = 0; o << g() << x << f() << x << x; expect("ostringstream 3", o.str(), "21177"); }

  trn = 0; tr[0] = 0;                              // (the probes above traced f and g too)
  // The object expression is evaluated before the arguments of a member call.
  obj().m(a1(), x);                                chk("member call", "oa");
  obj() << a1();                                   chk("member << call", "oa");
  (void)obj()[a1()];                               chk("member []", "oa");
  gm.s.clear(); x = 0; trn = 0; tr[0] = 0;
  obj().m(x, f());                                 chk("obj before args", "of");
  expect("args see x", gm.s, "0+1,");
  getc_()->m(a1(), x);                            chk("ptr member call", "cam");
  getr().m(a1(), x);                              chk("ref member call", "ram");
  getc_()->v(a1(), x);                            chk("virtual call", "caw");
  getr().v(a1(), x);                              chk("virtual call ref", "raw");

  // The function expression is evaluated before the arguments.
  (void)getfn()(a1());                             chk("fn pointer call", "gai");
  (void)getfn()(a1() + x);                        chk("fn pointer call 2", "gai");

  printf("%d failures\n", bad);
  return bad;
}
