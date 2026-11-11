// STD: c++11
// PAPER: N2439
// EXPECT: 0
struct A { int get() & { return 2; } int get() && { return 3; } };
int main() { A a; return a.get()!=2 || A().get()!=3; }
