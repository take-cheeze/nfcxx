// The recursive call's arguments go through lowering temporaries, which get per-expression (decl ... temp) facts.
static int count(int *p, int n) { if (n == 0) return *p; *p += 1; return count(p, n - 1); }
int main() { int c = 0; return count(&c, 3) - 3; }
