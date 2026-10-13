// Scalar captures, float math, a 2-D range, item::get_linear_id, a device helper function and a captured struct.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <math.h>
#include <vector>

struct Params { float a; int shift; };

static float poly(float x) { return x * x * 0.5f - x + 3.0f; }

int main() {
  int fails = 0;
  {
    const int N = 513;
    std::vector<float> x(N), y(N), z(N, 0.0f);
    for (int i = 0; i < N; i++) { x[i] = 0.25f * (float)i; y[i] = (float)(N - i); }
    float a = 2.5f;
    sycl::queue q;
    sycl::buffer<float> X(x), Y(y), Z(z);
    q.submit([&](sycl::handler &h) {
      sycl::accessor ax(X, h, sycl::read_only);
      sycl::accessor ay(Y, h, sycl::read_only);
      sycl::accessor az(Z, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::item<1> it) {
        size_t i = it.get_linear_id();
        az[i] = a * ax[i] + ay[i] + sycl::sqrt(ax[i]) - sycl::fabs(ay[i] - 100.0f);
      });
    });
    sycl::host_accessor hz(Z, sycl::read_only);
    for (int i = 0; i < N; i++) {
      float want = a * x[i] + y[i] + ::sqrtf(x[i]) - ::fabsf(y[i] - 100.0f);
      if (::fabsf(hz[i] - want) > 1e-3f * (1.0f + ::fabsf(want))) fails++;
    }
    std::printf("saxpy: %d bad\n", fails);
  }
  int f2 = 0;
  {
    const int R = 37, C = 50;
    std::vector<int> m(R * C, 0);
    Params p{1.5f, 3};
    sycl::queue q;
    sycl::buffer<int, 2> M(m.data(), sycl::range<2>(R, C));
    q.submit([&](sycl::handler &h) {
      sycl::accessor am(M, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<2>(R, C), [=](sycl::id<2> id) {
        int r = (int)id[0], c = (int)id[1];
        am[id] = r * 1000 + c + p.shift + (int)poly(p.a);
      });
    });
    q.wait();
    sycl::host_accessor hm(M, sycl::read_only);
    for (int r = 0; r < R; r++)
      for (int c = 0; c < C; c++)
        if (hm[sycl::id<2>(r, c)] != r * 1000 + c + 3 + (int)poly(1.5f)) f2++;
    std::printf("grid: %d bad\n", f2);
  }
  fails += f2;
  std::printf(fails ? "saxpy2d FAIL\n" : "saxpy2d ok\n");
  return fails != 0;
}
