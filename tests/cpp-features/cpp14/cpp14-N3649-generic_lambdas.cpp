// STD: c++14
// PAPER: N3649
// EXPECT: 0
int main() { auto add=[](auto a, auto b) { return a+b; }; return add(2,3)!=5 || add(1.25,2.5)!=3.75; }
