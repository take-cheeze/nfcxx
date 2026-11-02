// The vecAdd kernel as SYCL, on the Intel XPU (level_zero:gpu). The kernel adds a and b into c; main checks every element.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  sycl::queue q(sycl::gpu_selector_v);
  printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());
  const size_t n = 50000;
  std::vector<float> a(n), b(n), c(n);
  for (size_t i = 0; i < n; ++i) { a[i] = (float)i; b[i] = 2.0f * (float)i; }
  {
    sycl::buffer<float> A(a), B(b), C(c);
    q.submit([&](sycl::handler& h) {
      sycl::accessor ra(A, h, sycl::read_only);
      sycl::accessor rb(B, h, sycl::read_only);
      sycl::accessor rc(C, h, sycl::write_only);
      h.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) { rc[i] = ra[i] + rb[i]; });
    });
  }
  size_t bad = 0;
  for (size_t i = 0; i < n; ++i) bad += c[i] != 3.0f * (float)i;
  printf("mismatches: %zu of %zu\n", bad, n);
  return bad != 0;
}
