// STD: c++11
// PAPER: N2544
// EXPECT: 0
struct A { int x; A(int n):x(n) {} };
union U { A a; U():a(53) {} ~U() {} };
int main() { U u; return u.a.x!=53; }
