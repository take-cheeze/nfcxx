// STD: c++11
// PAPER: N2541
// EXPECT: 0
template<class A, class B> auto add(A a, B b) -> decltype(a+b) { return a+b; }
int main() { return add(2, 3L)!=5; }
