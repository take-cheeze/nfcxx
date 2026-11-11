// STD: c++11
// PAPER: N2930
// EXPECT: 0
int main() { int a[]={1,2,3}; for (auto& n:a) n*=2; int sum=0; for (int n:a) sum+=n; return sum!=12; }
