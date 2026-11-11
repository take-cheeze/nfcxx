// STD: c++14
// PAPER: N3653
// EXPECT: 0
struct A { int x=2; int y=3; };
int main() { A a{7}; return a.x!=7 || a.y!=3; }
