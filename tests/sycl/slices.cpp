// A grid of 300000 one-item groups: more groups than a Vulkan dispatch takes in one dimension (65535), so it is submitted in
// slices. Prints "slices ok".
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>
int main() {
  const int N = 300000;   // more than 65535 groups of 1 in a dimension when the local size is 1
  std::vector<int> a(N), b(N, 0);
  for (int i = 0; i < N; i++) a[i] = i;
  {
    sycl::queue q;
    sycl::buffer<int> A(a), B(b);
    q.submit([&](sycl::handler &h) {
      sycl::accessor x(A, h, sycl::read_only);
      sycl::accessor y(B, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::nd_range<1>(sycl::range<1>(N), sycl::range<1>(1)), [=](sycl::nd_item<1> it) {
        size_t i = it.get_global_id(0);
        y[i] = x[i] * 2 + 1;
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) if (b[i] != 2 * i + 1) bad++;
  std::printf(bad ? "slices FAIL %d\n" : "slices ok\n", bad);
  return bad != 0;
}
