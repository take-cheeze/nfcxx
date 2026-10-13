#include <sycl/sycl.hpp>
#include <cmath>
#include <algorithm>
#include <cstdio>
int main() {
  const int N = 64;
  std::vector<float> a(N), o(N);
  for (int i = 0; i < N; i++) a[i] = 0.1f * (float)(i + 1);
  {
    sycl::queue q;
    sycl::buffer<float> A(a), O(o);
    q.submit([&](sycl::handler& h) {
      sycl::accessor x(A, h, sycl::read_only);
      sycl::accessor y(O, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        float v = x[i];
        y[i] = std::sqrt(v) + sqrtf(v) + std::fabs(v - 2.0f) + std::exp(v * 0.1f) + std::pow(v, 1.5f) + std::floor(v) + std::fmax(v, 3.0f) +
               std::min(v, 3.0f) + std::max(v, 3.0f) + std::sin(v) + std::cos(v) + std::log(v) + std::tanh(v) + std::fmod(v, 2.0f) + (float)std::abs((int)(v * 10.0f) - 20);
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    float v = a[i];
    float w = std::sqrt(v) + sqrtf(v) + std::fabs(v - 2.0f) + std::exp(v * 0.1f) + std::pow(v, 1.5f) + std::floor(v) + std::fmax(v, 3.0f) +
               std::min(v, 3.0f) + std::max(v, 3.0f) + std::sin(v) + std::cos(v) + std::log(v) + std::tanh(v) + std::fmod(v, 2.0f) + (float)std::abs((int)(v * 10.0f) - 20);
    if (std::fabs(o[i] - w) > 2e-3f * (1.0f + std::fabs(w))) { bad++; if (bad < 4) std::printf("i=%d got %f want %f\n", i, o[i], w); }
  }
  std::printf(bad ? "libm FAIL %d\n" : "libm ok\n", bad);
  return bad != 0;
}
