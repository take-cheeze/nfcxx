// STD: c++11
// PAPER: N2235
// EXPECT: 0
constexpr int square(int x) { return x*x; }
static_assert(square(7) == 49, "constant");
int main() { return square(8) != 64; }
