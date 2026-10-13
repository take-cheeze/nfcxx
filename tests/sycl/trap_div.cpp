// A kernel that divides by zero: the run must fail (exit 71) and say why. Expected on the host path: no failure.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>
int main() {
  std::vector<int> a(16, 7), z(16, 0), o(16, 0);
  {
    sycl::queue q;
    sycl::buffer<int> A(a), Z(z), O(o);
    q.submit([&](sycl::handler &h) {
      sycl::accessor x(A, h, sycl::read_only);
      sycl::accessor y(Z, h, sycl::read_only);
      sycl::accessor r(O, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(16), [=](sycl::id<1> i) { r[i] = y[i] != 0 ? x[i] / y[i] : x[i] / (y[i] + (int)(i == 5 ? 0 : 1)); });
    });
  }
  std::printf("trap_div finished\n");
  return 0;
}
