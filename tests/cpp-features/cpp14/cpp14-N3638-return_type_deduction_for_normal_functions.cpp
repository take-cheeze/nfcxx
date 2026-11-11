// STD: c++14
// PAPER: N3638
// EXPECT: 0
auto twice(int n) { return n+n; }
decltype(auto) alias(int& n) { return (n); }
int main() { int n=3; alias(n)=8; return n!=8 || twice(9)!=18; }
