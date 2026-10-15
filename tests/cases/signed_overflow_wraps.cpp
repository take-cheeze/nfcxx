// EXPECT: 1
// Signed overflow is UB in C; nfcxx must give it wrapping semantics.
__attribute__((noinline)) bool wraps(int a){ return a + 1 < a; }
int main(){ return wraps(2147483647) ? 1 : 0; }
