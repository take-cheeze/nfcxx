// STD: c++11
// PAPER: N2341
// EXPECT: 0
alignas(32) int values[8];
int main() { return reinterpret_cast<unsigned long>(values) % 32 != 0; }
