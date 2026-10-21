// STD: c++17
// PAPER: N4295
// EXPECT: 6
template<class... A> int sum(A... a) { return (0 + ... + a); }
int main() { return sum(1, 2, 3); }
