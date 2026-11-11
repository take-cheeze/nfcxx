// STD: c++11
// PAPER: N1757
// EXPECT: 0
template<class T> struct Box { T value; };
int main() { Box<Box<int>> b={{13}}; return b.value.value!=13; }
