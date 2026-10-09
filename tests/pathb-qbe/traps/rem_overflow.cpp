// Checked remainder: INT_MIN % -1 must abort (crem).
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int rem(int a, int b) { return a % b; }
int main() { return rem(-2147483647 - 1, id(-1)); }
