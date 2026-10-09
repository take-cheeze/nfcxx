// Checked division: a zero divisor must abort (cdiv).
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int quot(int a, int b) { return a / b; }
int main() { return quot(10, id(0)); }
