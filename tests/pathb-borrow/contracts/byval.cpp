// A struct passed by value: the callee gets (byval T) and its own initialized copy.
struct V { int a; char c; long d; };
static long sum(V v) { return v.a + v.c + v.d; }
int main() { V v; v.a = 1; v.c = 2; v.d = 3; return (int)sum(v) - 6; }
