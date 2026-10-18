// Two kernels for the SYCL pre-pass regression (tests/oneapi/run.sh): a lambda that captures nothing and one that captures an int.
#include <sycl/sycl.hpp>

int main() {
  sycl::queue q{sycl::gpu_selector_v};
  int n = 3;
  q.submit([&](sycl::handler& h) {
    h.parallel_for(sycl::range<1>(16), [=](sycl::id<1> i) { (void)i; });
  });
  q.submit([&](sycl::handler& h) {
    h.parallel_for(sycl::range<1>(4), [=](sycl::id<1> i) { int x = n + (int)i[0]; (void)x; });
  });
  return 0;
}
