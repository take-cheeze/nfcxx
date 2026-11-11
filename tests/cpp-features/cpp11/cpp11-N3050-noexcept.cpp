// STD: c++11
// PAPER: N3050
// EXPECT: 0
int f() noexcept { return 71; }
int g() { return 1; }
static_assert(noexcept(f()) && !noexcept(g()), "exception specification");
int main() { return f()!=71; }
