// STD: c++11
// PAPER: N2765
// EXPECT: 0
constexpr unsigned long long operator"" _triple(unsigned long long n) { return 3*n; }
int main() { return 14_triple!=42; }
