// EXPECT: 75
// rep<16> and get<7> are instantiated explicitly here. b.cpp calls them with no definition of its own.
// a: rep<16> on {1, 2} gives {17, 18}, 35. b_work() gives 40 (b's rep<16> on {0, 0} is 32, get<7>(1) is 8). Total 75.
#include "common.h"
template <int N> void rep(int * p, int n) { for (int i = 0; i < n; i++) p[i] += N; }
template void rep<16>(int *, int);
template <int N> int get(int x) { return x + N; }
template int get<7>(int);
int main() {
  int a[2] = {1, 2};
  rep<16>(a, 2);
  return a[0] + a[1] + b_work();
}
