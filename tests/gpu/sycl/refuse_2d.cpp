// A two-dimensional range is not lowered yet (the device rewrite handles range<1> only).
#include <sycl/sycl.hpp>

void run(sycl::queue &q, sycl::buffer<float, 2> &A) {
  q.submit([&](sycl::handler &h) {
    sycl::accessor ra(A, h, sycl::read_only);
    h.parallel_for(sycl::range<2>(4, 4), [=](sycl::id<2> i) { (void)ra; });
  });
}
