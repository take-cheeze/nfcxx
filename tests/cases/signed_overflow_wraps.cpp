// EXPECT: 1
// X86-ONLY: the EDG front end on aarch64 rejects a long double literal (x86-64 long double layout), so this case is skipped there
// Signed overflow is UB in C; nfcxx must give it wrapping semantics.
__attribute__((noinline)) bool wraps(int a){ return a + 1 < a; }
int main(){ return wraps(2147483647) ? 1 : 0; }
