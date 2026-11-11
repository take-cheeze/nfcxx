// A bool converted to float in a kernel (the gate of a piecewise op: (xi > 0.0f) as a float). Expected output: "bool_to_float ok".
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int N = 64;
  std::vector<float> x(N), r(N, -1.0f);
  for (int i = 0; i < N; i++) x[i] = 0.25f * (float)i - 8.0f;
  {
    sycl::queue q;
    sycl::buffer<float, 1> X(x.data(), sycl::range<1>(N)), R(r.data(), sycl::range<1>(N));
    q.submit([&](sycl::handler &h) {
      sycl::accessor rx(X, h, sycl::read_only);
      sycl::accessor wr(R, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        const float xi = rx[i];
        const float gate_pos = (xi > 0.0f);   // bool -> float: 1.0 or 0.0
        wr[i] = gate_pos * (3.0f * xi) + (1.0f - gate_pos) * (-0.5f * xi);
      });
    });
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    const float xi = x[i];
    const float g = xi > 0.0f ? 1.0f : 0.0f;
    const float want = g * (3.0f * xi) + (1.0f - g) * (-0.5f * xi);
    if (r[i] != want) bad++;
  }
  std::printf(bad ? "bool_to_float FAIL %d\n" : "bool_to_float ok\n", bad);
  return bad != 0;
}
