// STD: c++11
// PAPER: N2634
// EXPECT: 0
template<class T> auto read(T t) -> decltype(t.get()) { return t.get(); }
int read(...) { return 2; }
struct A { int get() { return 3; } };
int main() { return read(A())!=3 || read(7)!=2; }
