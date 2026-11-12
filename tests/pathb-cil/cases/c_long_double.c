// EXPECT-REFUSED: helper of nfcxx's runtime
long double add(long double a, long double b) { return a + b; }
int main(void) { return (int)add(40.0L, 2.0L) - 42; }
