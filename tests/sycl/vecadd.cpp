// SYCL vector add: buffers, accessors, parallel_for over a range. Expected output: "vecadd ok".
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int N = 1000;
  std::vector<float> a(N), b(N), c(N, -1.0f);
  for (int i = 0; i < N; i++) { a[i] = (float)i; b[i] = 2.0f * (float)i + 1.0f; }
  {
    sycl::queue q;
    sycl::buffer<float, 1> A(a.data(), sycl::range<1>(N)), B(b.data(), sycl::range<1>(N)), C(c.data(), sycl::range<1>(N));
    q.submit([&](sycl::handler &h) {
      sycl::accessor ra(A, h, sycl::read_only);
      sycl::accessor rb(B, h, sycl::read_only);
      sycl::accessor wc(C, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { wc[i] = ra[i] + rb[i]; });
    });
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N; i++)
    if (c[i] != a[i] + b[i]) bad++;
  std::printf(bad ? "vecadd FAIL %d\n" : "vecadd ok\n", bad);
  return bad != 0;
}
