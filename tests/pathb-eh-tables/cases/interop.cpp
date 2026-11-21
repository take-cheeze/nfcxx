// EXPECT: 0
// STDOUT: same
#include <stdio.h>
int ext_throw(int x);              // gcc: throws x when x > 0
void ext_call(void (*f)(int), int); // gcc: catches int, prints
struct D { int *p; int tag; D(int *q, int t) : p(q), tag(t) {} ~D() { *p = *p * 10 + tag; } };
int g(int x, int *cnt) {
  D outer(cnt, 1);
  try { D inner(cnt, 2); return ext_throw(x); }
  catch (int e) { D h(cnt, 3); return 100 + e; }
  catch (...) { throw; }
}
void cleanup_only(int x) { int c = 0; D a(&c, 4); D b(&c, 5); ext_throw(x); printf("no throw c=%d\n", c); }
static int tcnt; void thrower(int x) { if (x) throw D(&tcnt, 9); }
struct Err { int code; };
int catch_class(int x) { try { if (x) throw Err{x}; return 0; } catch (const Err &e) { return e.code; } }
int catch_ptr(int x) { static int v = 77; try { if (x) throw &v; return 0; } catch (int *p) { return *p; } }
int nested(int x) {
  int r = 0;
  try { try { ext_throw(x); } catch (long) { r = -1; } }
  catch (int e) { r = e * 2; }
  return r;
}
int main() {
  int cnt = 0;
  int r = g(0, &cnt);
  printf("g0=%d cnt=%d\n", r, cnt);
  cnt = 0; r = g(5, &cnt);
  printf("g5=%d cnt=%d\n", r, cnt);
  ext_call(cleanup_only, 0);
  ext_call(cleanup_only, 7);
  try { thrower(1); } catch (D &d) { printf("caught D tag=%d\n", d.tag); }
  int c = catch_class(42), p = catch_ptr(1), n1 = nested(21), n0 = nested(0);
  printf("class=%d ptr=%d nested=%d nested0=%d\n", c, p, n1, n0);
  return 0;
}
