// STD: c++17
// PAPER: N4267
// EXPECT: 0
int main() { char c = u8'a'; return c != 97 || sizeof(u8'a') != 1; }
