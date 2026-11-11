// STD: c++11
// PAPER: N2437
// EXPECT: 0
struct A { explicit operator bool() const { return true; } };
int main() { A a; return a ? 0 : 1; }
