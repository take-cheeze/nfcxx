// EXPECT: 120
constexpr int fact(int n){ return n<=1 ? 1 : n*fact(n-1); }
static_assert(fact(5)==120);
int main(){ return fact(5); }
// X86-ONLY: the EDG front end on aarch64 rejects a long double literal (x86-64 long double layout), so this case is skipped there
