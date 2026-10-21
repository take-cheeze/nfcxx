// STD: c++17
// PAPER: P0292R2
// EXPECT: 1
struct Empty {};
template<class T> int f(T t) { if constexpr (sizeof(T) == 4) return 1; else return t.missing(); }
int main() { return f(1); }
