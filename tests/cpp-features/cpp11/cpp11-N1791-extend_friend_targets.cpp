// STD: c++11
// PAPER: N1791
// EXPECT: 0
template<class T> class Box { friend T; int value = 23; };
struct Reader { int read(Box<Reader>& b) { return b.value; } };
int main() { Box<Reader> b; Reader r; return r.read(b) != 23; }
