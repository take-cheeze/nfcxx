// STD: c++11
// PAPER: N1811
// EXPECT: 0
static_assert(sizeof(long long)>=8, "width");
int main() { long long n=1LL<<40; return n/1024 != (1LL<<30); }
