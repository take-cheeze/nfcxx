// STD: c++11
// PAPER: N1984
// EXPECT: 0
int main() { auto n = 17; auto p = &n; return *p != 17; }
