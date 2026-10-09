// Checked shift: a count equal to the width of the type must abort (cshl).
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int shl(int a, int n) { return a << n; }
int main() { return shl(1, id(32)); }
