// STD: c++11
// PAPER: N2341
// EXPECT: 0
struct alignas(32) A { char x; };
static_assert(alignof(A) == 32, "alignment");
int main() { return 0; }
