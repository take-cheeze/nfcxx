// double precision in a kernel: valid on Vulkan (Float64) and on the host path; WebGPU refuses it (refuse_double.cpp).
#include <sycl/sycl.hpp>
#include <cstdio>
#include <cmath>
#include <vector>

int main() {
  const int N = 300;
  std::vector<double> x(N), y(N, 0.0);
  std::vector<long long> big(N, 0);
  for (int i = 0; i < N; i++) x[i] = 0.5 * i - 20.25;
  {
    sycl::queue q;
    sycl::buffer<double> X(x), Y(y);
    sycl::buffer<long long> B(big);
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(X, h, sycl::read_only);
      sycl::accessor b(Y, h, sycl::write_only, sycl::no_init);
      sycl::accessor c(B, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        double v = a[i];
        b[i] = v * v / 3.0 - 2.0 * v + 0.125;
        c[i] = (long long)(v * 1000.0) * 1000000007LL;
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    double v = x[i];
    double w = v * v / 3.0 - 2.0 * v + 0.125;
    if (std::fabs(y[i] - w) > 1e-12 * (1.0 + std::fabs(w))) bad++;
    if (big[i] != (long long)(v * 1000.0) * 1000000007LL) bad++;
  }
  std::printf(bad ? "double FAIL %d\n" : "double ok\n", bad);
  return bad != 0;
}
