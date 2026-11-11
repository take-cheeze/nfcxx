// A local std::array in a kernel: its operator[] and constructor reach libstdc++'s exception-handling state only
// on paths the kernel never takes, so the device pass must lower it like a C array. Expected output: "std_array ok".
#include <sycl/sycl.hpp>
#include <array>
#include <cstdio>
#include <vector>

int main() {
  const int N = 16;
  std::vector<int> out(N, -1);
  {
    sycl::queue q;
    sycl::buffer<int, 1> O(out.data(), sycl::range<1>(N));
    q.submit([&](sycl::handler &h) {
      sycl::accessor wo(O, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        std::array<int, 2> ix = {0, 1};
        wo[i] = ix[i[0] & 1] * 10 + ix[(i[0] >> 1) & 1];
      });
    });
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N; i++)
    if (out[i] != ((i & 1) * 10 + ((i >> 1) & 1))) bad++;
  std::printf(bad ? "std_array FAIL %d\n" : "std_array ok\n", bad);
  return bad != 0;
}
