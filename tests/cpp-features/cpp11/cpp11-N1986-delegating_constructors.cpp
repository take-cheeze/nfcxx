// STD: c++11
// PAPER: N1986
// EXPECT: 0
struct A { int x; A(int n): x(n) {} A(): A(19) {} };
int main() { A a; return a.x != 19; }
