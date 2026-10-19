// STD: c++11
// PAPER: N1653
// EXPECT: 0
#define SUM(a, ...) ((a) + (__VA_ARGS__))
_Pragma("once")
int main() { return SUM(3, 4) != 7 || __func__[0] != 'm'; }
