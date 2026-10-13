// A kernel using double: the device compile must refuse it (exit 3) and name the type.
#include <sycl/sycl.hpp>
#include <vector>
int main() {
  std::vector<double> a(16, 1.0);
  sycl::queue q;
  sycl::buffer<double> A(a);
  q.submit([&](sycl::handler &h) {
    sycl::accessor x(A, h);
    h.parallel_for(sycl::range<1>(16), [=](sycl::id<1> i) { x[i] = x[i] * 2.0; });
  });
  return 0;
}
