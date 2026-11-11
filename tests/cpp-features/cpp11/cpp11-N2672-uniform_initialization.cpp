// STD: c++11
// PAPER: N2672
// EXPECT: 0
struct A { int x; A(int n):x(n) {} };
int main() { A a{67}; int xs[]{2,3}; return a.x!=67 || xs[1]!=3; }
