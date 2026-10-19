// STD: c++11
// PAPER: N2442
// EXPECT: 0
int main() { const char* s=u8"\u00e9"; return (unsigned char)s[0]!=0xc3 || (unsigned char)s[1]!=0xa9 || s[2]!=0; }
