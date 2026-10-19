// STD: c++11
// PAPER: N2347
// EXPECT: 0
enum class E : unsigned char { answer=43 };
int main() { return static_cast<unsigned>(E::answer)!=43 || sizeof(E)!=1; }
