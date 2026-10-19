// STD: c++11
// PAPER: N1720
// EXPECT: 0
template<int N> struct A { static_assert(N>0, "positive"); int x[N]; };
int main() { A<3> a={{2,4,6}}; return a.x[2]!=6; }
