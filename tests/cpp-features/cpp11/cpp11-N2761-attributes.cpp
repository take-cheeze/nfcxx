// STD: c++11
// PAPER: N2761
// EXPECT: 0
[[noreturn]] void stop() { for (;;) {} }
int main() { return 0; }
