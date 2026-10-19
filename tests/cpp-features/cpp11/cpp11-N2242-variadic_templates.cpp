// STD: c++11
// PAPER: N2242
// EXPECT: 0
int sum() { return 0; }
template<class T, class... Rest> int sum(T n, Rest... rest) { return n+sum(rest...); }
int main() { return sum(2,3,5,7)!=17; }
