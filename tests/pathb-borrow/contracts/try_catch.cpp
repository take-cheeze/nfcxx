// try/catch through EDG's _setjmp try blocks: a typed clause with a catch (...) after it, and a rethrow from an
// inner handler to an outer one. The summaries are inferred and the program runs natively.
struct E { int code; E(int c) : code(c) {} };
static void may(int *p) { if (*p == 7) throw E(*p); *p += 1; }
static int caught(int start) {
  int x = start;
  try { may(&x); } catch (const E &e) { x = e.code + 100; } catch (...) { x = -1; }
  return x;
}
static int nested(int start) {
  int x = start;
  try { try { may(&x); } catch (...) { x = 5; throw; } } catch (...) { return x; }
  return x;
}
int main() {
  return caught(1) + caught(7) + nested(7) + nested(1) - (2 + 107 + 5 + 2);
}
