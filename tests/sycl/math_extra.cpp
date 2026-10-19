// sycl::erf, sycl::expm1 and sycl::log1p in a kernel (ggml's op_erf, op_expm1, op_softplus, op_elu, op_gelu_erf). They
// lower to OpenCL.std erf, expm1 and log1p (pathb-spirv-emit.rb); before, a kernel that called one trapped (exit 71).
// Each result is checked against the host's double-precision value.
#include <sycl/sycl.hpp>
#include <cmath>
#include <cstdio>
#include <vector>
int main() {
  const int N = 64;
  std::vector<float> a(N), e(N), m(N), l(N);
  for (int i = 0; i < N; i++) a[i] = -4.0f + 8.0f * (float)i / (float)(N - 1);
  {
    sycl::queue q;
    sycl::buffer<float> A(a), E(e), M(m), L(l);
    q.submit([&](sycl::handler& h) {
      sycl::accessor x(A, h, sycl::read_only);
      sycl::accessor ye(E, h, sycl::write_only, sycl::no_init);
      sycl::accessor ym(M, h, sycl::write_only, sycl::no_init);
      sycl::accessor yl(L, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        float v = x[i];
        ye[i] = sycl::erf(v);
        ym[i] = sycl::expm1(v);
        yl[i] = sycl::log1p(v + 4.0f);   // log1p of (v + 4) >= 0, so the argument is in the domain
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    double v = a[i];
    double we = std::erf(v), wm = std::expm1(v), wl = std::log1p(v + 4.0);
    double tol = 1e-5 * (1.0 + std::fabs(we));
    if (std::fabs(e[i] - we) > tol) { bad++; if (bad < 4) std::printf("erf i=%d got %f want %f\n", i, e[i], we); }
    tol = 1e-5 * (1.0 + std::fabs(wm));
    if (std::fabs(m[i] - wm) > tol) { bad++; if (bad < 4) std::printf("expm1 i=%d got %f want %f\n", i, m[i], wm); }
    tol = 1e-5 * (1.0 + std::fabs(wl));
    if (std::fabs(l[i] - wl) > tol) { bad++; if (bad < 4) std::printf("log1p i=%d got %f want %f\n", i, l[i], wl); }
  }
  std::printf(bad ? "math_extra FAIL %d\n" : "math_extra ok\n", bad);
  return bad != 0;
}
