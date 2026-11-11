// STD: c++11
// PAPER: N2927
// EXPECT: 0
int main() { int n=3; auto f=[n](int k) mutable { return n+=k; }; return f(4)!=7 || f(2)!=9 || n!=3; }
