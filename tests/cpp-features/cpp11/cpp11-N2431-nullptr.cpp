// STD: c++11
// PAPER: N2431
// EXPECT: 0
int which(int) { return 1; }
int which(int*) { return 2; }
int main() { int* p=nullptr; return p!=nullptr || which(nullptr)!=2; }
