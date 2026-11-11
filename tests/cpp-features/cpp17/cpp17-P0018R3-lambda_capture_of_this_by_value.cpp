// STD: c++17
// PAPER: P0018R3
// EXPECT: 6
struct S { int v; auto f() { return [*this] { return v; }; } };
int main() { S s{6}; return s.f()(); }
