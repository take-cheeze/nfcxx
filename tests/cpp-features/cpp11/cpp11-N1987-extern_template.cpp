// STD: c++11
// PAPER: N1987
// EXPECT: 0
template<class T> int twice(T n) { return n+n; }
extern template int twice<int>(int);
template int twice<int>(int);
int main() { return twice(8) != 16; }
