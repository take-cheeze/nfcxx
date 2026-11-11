// STD: c++17
// PAPER: P0217R3
// EXPECT: 6
struct P { int a; int b; };
int main() { P p{2, 3}; auto [x, y] = p; return x * y; }
