// EXPECT: 41
// The callee throws; the caller's catch receives the value (inner throws 40, outer returns 40 + 1).
static int inner(int x) { if (x > 0) throw x * 2; return 0; }
static int outer(int x) { try { return inner(x) + 1; } catch (int e) { return e + 1; } }
int main(void) { return outer(20); }
