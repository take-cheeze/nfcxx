// STD: c++17
// PAPER: P0386R2
// EXPECT: 5
struct S { static inline int x = 5; };
inline constexpr int k = 2;
int main() { return S::x + k - 2; }
