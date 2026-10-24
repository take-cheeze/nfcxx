// EXPECT: 0
// GNU statement expressions ({ ... }): the value of the last expression statement, evaluated where the expression is
// (the branch of ?:, && and ||, a loop condition), with return, goto and break leaving the body as jumps. The exit code
// names the first check that fails. cproc (the qbe backend) gained them with scripts/setup-qbe.sh's pin 9f706f5.
typedef struct { int state; long value; } RESULT;
static int calls;
static RESULT mk(int st, long v) { RESULT r = { st, v }; calls++; return r; }

// the shape ASTro uses: a return from the middle of an expression
#define UNWRAP(r) ({ RESULT _r = (r); if (_r.state) return _r.state; _r.value; })
#define MAX(a, b) ({ int _a = (a), _b = (b); _a > _b ? _a : _b; })

static int unwrap(int st, long *out) { long v = UNWRAP(mk(st, 40)); *out = v + 2; return 0; }
static int cond(int c) { calls = 0; int x = c ? ({ calls += 10; 5; }) : 7; return x * 100 + calls; }
static int logic(int c) { calls = 0; int x = c && ({ calls += 1; 1; }); int y = c || ({ calls += 100; 1; }); return x * 10000 + y * 1000 + calls; }
static int loop(void) { int i = 0, n = 0; while (({ n++; i < 5; })) i++; return n * 10 + i; }
static int nested(void) { return ({ int a = 3; int b = ({ int c = a * 2; c + 1; }); a + b; }); }
static int sidefx(int *p) { int v = ({ int t = *p; *p = t + 1; t; }) + ({ int t = *p; *p = t + 10; t; }); return v * 100 + *p; }
static RESULT strct(void) { return ({ RESULT r = { 1, 2 }; r.value += 3; r; }); }
static int voidexpr(int *p) { ({ *p = 9; }); (void)({ if (*p) *p += 1; }); return *p; }
static int sw(int k) { return ({ int r; switch (k) { case 1: r = 10; break; default: r = 20; } r; }); }
static const char *str(void) { return ({ static const char s[] = "hi"; s; }); }
static int gt(int k) { int s = 0; for (int i = 0; i < 4; i++) s += ({ int t = i; if (t == k) goto out; t; }); out: return s; }
static int brk(void) { int s = 0; for (int i = 0; i < 10; i++) s += ({ if (i == 3) break; i; }); return s; }

int main(void) {
  long o = 0;
  if (unwrap(0, &o) != 0 || o != 42) return 1;
  o = 0;
  if (unwrap(7, &o) != 7 || o != 0) return 2;       // the early return skipped the store
  if (MAX(3, 9) + MAX(-1, -2) != 8) return 3;
  if (cond(1) != 510 || cond(0) != 700) return 4;   // the body of the branch not taken did not run
  if (logic(1) != 11001 || logic(0) != 1100) return 5;
  if (loop() != 65) return 6;                       // the condition's body ran for every test
  if (nested() != 10) return 7;
  int q = 1;
  if (sidefx(&q) != 312) return 8;
  RESULT r = strct();
  if (r.state != 1 || r.value != 5) return 9;
  int z = 0;
  if (voidexpr(&z) != 10) return 10;
  if (sw(1) != 10 || sw(5) != 20) return 11;
  const char *h = str();
  if (h[0] != 'h' || h[1] != 'i' || h[2] != 0) return 12;
  if (gt(2) != 1 || gt(9) != 6) return 13;
  if (brk() != 3) return 14;
  if (sizeof(({ 1L; })) != 8 || sizeof(({ char c = 1; c; })) != 1) return 15;
  return 0;
}
