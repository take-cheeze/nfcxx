// STD: c++11
// PAPER: N2346
// EXPECT: 0
struct A { int x; A() = default; A(const A&) = delete; };
int main() { A a{}; return a.x; }
