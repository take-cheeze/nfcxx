// STD: c++11
// PAPER: N2657
// EXPECT: 0
template<class T> int read(T t) { return t.x; }
int main() { struct Local { int x; }; struct { int x; } a={5}; Local b={7}; return read(a)+read(b)!=12; }
