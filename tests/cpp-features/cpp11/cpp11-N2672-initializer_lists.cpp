// STD: c++11
// PAPER: N2672
// EXPECT: 0
#include <initializer_list>
struct A { int sum; A(std::initializer_list<int> xs):sum(0) { for (int n:xs) sum+=n; } };
int main() { A a={3,5,7}; return a.sum!=15; }
