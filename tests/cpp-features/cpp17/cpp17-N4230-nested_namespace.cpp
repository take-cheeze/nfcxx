// STD: c++17
// PAPER: N4230
// EXPECT: 4
namespace A::B { int f() { return 4; } }
int main() { return A::B::f(); }
