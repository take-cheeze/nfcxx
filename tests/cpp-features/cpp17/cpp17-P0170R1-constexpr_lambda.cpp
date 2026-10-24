// STD: c++17
// PAPER: P0170R1
// EXPECT: 3
int main() { constexpr int v = [](int x) { return x + 1; }(2); return v; }
