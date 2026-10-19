// STD: c++11
// PAPER: N2258
// EXPECT: 0
template<class T> using Pointer = T*;
int main() { int n=47; Pointer<int> p=&n; return *p!=47; }
