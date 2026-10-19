// STD: c++11
// PAPER: N2540
// EXPECT: 0
struct Base { int x; Base(int n): x(n) {} };
struct Derived : Base { using Base::Base; };
int main() { Derived d(29); return d.x != 29; }
