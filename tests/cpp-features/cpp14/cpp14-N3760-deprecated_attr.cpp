// STD: c++14
// PAPER: N3760
// EXPECT: 0
[[deprecated("probe")]] int old() { return 83; }
int main() { return old()!=83; }
