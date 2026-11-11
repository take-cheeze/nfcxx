// sycl::erf, sycl::expm1 and sycl::log1p on double in a kernel. They lower to the OpenCL.std erf, expm1 and log1p on
// Float64 (pathb-spirv-emit.rb, __nfcxx_sycl_fn1_f64); before, a double call trapped (exit 71). Checked against the
// host's double-precision value.
#include <sycl/sycl.hpp>
#include <cmath>
#include <cstdio>
#include <vector>
int main() {
  const int N = 64;
  std::vector<double> a(N), e(N), m(N), l(N);
  for (int i = 0; i < N; i++) a[i] = -4.0 + 8.0 * (double)i / (double)(N - 1);
  {
    sycl::queue q;
    sycl::buffer<double> A(a), E(e), M(m), L(l);
    q.submit([&](sycl::handler& h) {
      sycl::accessor x(A, h, sycl::read_only);
      sycl::accessor ye(E, h, sycl::write_only, sycl::no_init);
      sycl::accessor ym(M, h, sycl::write_only, sycl::no_init);
      sycl::accessor yl(L, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        double v = x[i];
        ye[i] = sycl::erf(v);
        ym[i] = sycl::expm1(v);
        yl[i] = sycl::log1p(v + 4.0);   // log1p of (v + 4) >= 0, so the argument is in the domain
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    double v = a[i];
    double we = std::erf(v), wm = std::expm1(v), wl = std::log1p(v + 4.0);
    double tol = 1e-9 * (1.0 + std::fabs(we));
    if (std::fabs(e[i] - we) > tol) { bad++; if (bad < 4) std::printf("erf i=%d got %.17g want %.17g\n", i, e[i], we); }
    tol = 1e-9 * (1.0 + std::fabs(wm));
    if (std::fabs(m[i] - wm) > tol) { bad++; if (bad < 4) std::printf("expm1 i=%d got %.17g want %.17g\n", i, m[i], wm); }
    tol = 1e-9 * (1.0 + std::fabs(wl));
    if (std::fabs(l[i] - wl) > tol) { bad++; if (bad < 4) std::printf("log1p i=%d got %.17g want %.17g\n", i, l[i], wl); }
  }
  std::printf(bad ? "math_extra_f64 FAIL %d\n" : "math_extra_f64 ok\n", bad);
  return bad != 0;
}
