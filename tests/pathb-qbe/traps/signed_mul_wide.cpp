// Signed 64-bit overflow with NFCXX_IR_OVERFLOW=trap (csub on long): aborts.
__attribute__((noinline)) long id(long x) { return x; }
__attribute__((noinline)) long sub(long a, long b) { return a - b; }
int main() { return (int)sub(-9223372036854775807L - 1, id(1)); }
