// STD: c++17
// PAPER: N3922
// EXPECT: 0
template<class T> struct is_int { static const int v = 0; };
template<> struct is_int<int> { static const int v = 1; };
int main() { auto x{3}; return is_int<decltype(x)>::v ? 0 : 1; }
