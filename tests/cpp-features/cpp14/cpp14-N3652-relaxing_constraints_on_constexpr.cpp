// STD: c++14
// PAPER: N3652
// EXPECT: 0
constexpr int sum(int n) { int s=0; for(int i=1;i<=n;++i) s+=i; if(s>10) s-=1; return s; }
static_assert(sum(5)==14, "loop");
int main() { return sum(4)!=10; }
