// Checked division: INT_MIN / -1 must abort (cdiv), it is not representable.
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int quot(int a, int b) { return a / b; }
int main() { return quot(-2147483647 - 1, id(-1)); }
