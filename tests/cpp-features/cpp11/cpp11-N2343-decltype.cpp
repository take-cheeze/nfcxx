// STD: c++11
// PAPER: N2343
// EXPECT: 0
int main() { int n = 3; decltype((n)) alias = n; alias = 9; return n != 9; }
