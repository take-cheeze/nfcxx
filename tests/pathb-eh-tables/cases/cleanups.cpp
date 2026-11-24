// STDOUT: same
// EXPECT: 0
#include <stdio.h>
#include <new>
static int trace[64], nt;
static void note(int v) { trace[nt++] = v; }
static int fail_at = -1, made = 0;
struct T {
  int id;
  T(int i) : id(i) { if (made++ == fail_at) throw 1000 + i; note(i); }
  T(const T &o) : id(o.id + 50) { if (made++ == fail_at) throw 2000 + id; note(id); }
  ~T() { note(-id); }
};
static T make(int i) { return T(i); }
static int use1(const T &a) { return a.id; }
static int f_cond(bool c) { return c ? (use1(T(1)), use1(make(2))) : (use1(make(3)), use1(T(4))); }
static T *f_new() { return new T(7); }
static void f_arr() { T a[4] = {10, 11, 12, 13}; note(99); }
struct Base { int b; Base() : b(1) { note(200); } ~Base() { note(-200); } };
struct Mem { Mem() { note(300); } ~Mem() { note(-300); } };
struct Derived : Base { Mem m; T t; Derived() : t(20) { note(400); } ~Derived() { note(-400); } };
static void f_derived() { Derived d; note(98); }
static T &f_static() { static T s(30); return s; }
static int f_full() { return (use1(T(40)), use1(T(41)), use1(make(42)), use1(T(43)), 0); }
typedef void (*fn)();
static void run(const char *name, fn f, int fails) {
  for (int k = -1; k < fails; k++) {
    nt = 0; made = 0; fail_at = k;
    int caught = 0;
    try { f(); } catch (int e) { caught = e; }
    printf("%s fail@%d caught=%d trace:", name, k, caught);
    for (int i = 0; i < nt; i++) printf(" %d", trace[i]);
    printf("\n");
  }
}
static void c1() { f_cond(true); }
static void c0() { f_cond(false); }
static void cn() { T *p = f_new(); delete p; }
static void cs() { f_static(); }
int main() {
  run("cond1", c1, 4); run("cond0", c0, 4); run("new", cn, 2); run("arr", f_arr, 5);
  run("derived", f_derived, 2); run("static", cs, 2); run("full", (fn)[]{ f_full(); }, 7);
  return 0;
}
