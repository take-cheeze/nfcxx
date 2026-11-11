// EXPECT: 120
constexpr int fact(int n){ return n<=1 ? 1 : n*fact(n-1); }
static_assert(fact(5)==120);
int main(){ return fact(5); }
