// EXPECT: 1
// Signed overflow is UB in C; nfcxx must give it wrapping semantics.
__attribute__((noinline)) bool wraps(int a){ return a + 1 < a; }
int main(){ return wraps(2147483647) ? 1 : 0; }
// X86-ONLY-LINUX: x86-64 long double layout, which the aarch64 Linux front end does not take; macOS arm64 runs it
