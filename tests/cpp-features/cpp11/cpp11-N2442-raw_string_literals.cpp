// STD: c++11
// PAPER: N2442
// EXPECT: 0
int main() { const char* s=R"tag(a\nb)tag"; return s[1]!='\\' || s[2]!='n' || s[4]!=0; }
