// STD: c++11
// PAPER: N2756
// EXPECT: 0
struct A { int x=61; int y=x+2; };
int main() { A a; return a.x!=61 || a.y!=63; }
