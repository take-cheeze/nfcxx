// copysign (float and double) in a kernel, and the sign of zero: |x| with the sign of y. Prints "copysign ok".
#include <sycl/sycl.hpp>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
  const int N = 64;
  std::vector<float> x(N), y(N), r(N);
  std::vector<double> dx(N), dy(N), dr(N);
  for (int i = 0; i < N; i++) {
    x[i] = 0.5f * (float)i - 9.0f;
    y[i] = (i % 3) - 1.0f;   // -1, 0, 1: the zero has a positive sign
    dx[i] = (double)x[i];
    dy[i] = (double)y[i];
  }
  {
    sycl::queue q;
    sycl::buffer<float> X(x), Y(y), R(r);
    sycl::buffer<double> DX(dx), DY(dy), DR(dr);
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(X, h, sycl::read_only), b(Y, h, sycl::read_only);
      sycl::accessor c(R, h, sycl::write_only, sycl::no_init);
      sycl::accessor da(DX, h, sycl::read_only), db(DY, h, sycl::read_only);
      sycl::accessor dc(DR, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        c[i] = std::copysign(a[i], b[i]);
        dc[i] = std::copysign(da[i], db[i]);
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    if (r[i] != std::copysign(x[i], y[i])) bad++;
    if (dr[i] != std::copysign(dx[i], dy[i])) bad++;
  }
  std::printf(bad ? "copysign FAIL %d\n" : "copysign ok\n", bad);
  return bad != 0;
}
