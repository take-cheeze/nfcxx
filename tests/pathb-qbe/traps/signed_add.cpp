// Signed overflow with NFCXX_IR_OVERFLOW=trap (cadd): the sum wraps in the default mode, aborts in trap mode.
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int add(int a, int b) { return a + b; }
int main() { return add(2147483647, id(1)); }
