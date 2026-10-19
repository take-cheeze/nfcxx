// STD: c++11
// PAPER: N2118
// EXPECT: 0
struct A { int x; A(int n):x(n) {} A(A&& a):x(a.x) { a.x=0; } A(const A&)=delete; };
int main() { A a(37); A b(static_cast<A&&>(a)); return a.x!=0 || b.x!=37; }
