// STD: c++11
// PAPER: N2928
// EXPECT: 0
struct A { virtual int get() const { return 1; } virtual ~A() {} };
struct B final : A { int get() const override final { return 59; } };
int main() { B b; A& a=b; return a.get()!=59; }
