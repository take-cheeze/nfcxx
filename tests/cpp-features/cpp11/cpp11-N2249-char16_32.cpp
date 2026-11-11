// STD: c++11
// PAPER: N2249
// EXPECT: 0
int main() { char16_t a=u'A'; char32_t b=U'\U0001F600'; return a!=65 || b!=0x1f600; }
