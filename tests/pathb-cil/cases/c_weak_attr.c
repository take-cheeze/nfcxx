// EXPECT-REFUSED: a weak function is not supported
__attribute__((weak)) int f(void) { return 1; }
int main(void) { return f(); }
