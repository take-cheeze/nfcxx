// STD: c++14
// PAPER: N3648
// EXPECT: 0
int main() { int n=3; auto f=[n=n+4, &ref=n]() mutable { ref+=2; return ++n; }; return f()!=8 || n!=5; }
