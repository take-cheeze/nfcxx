// One TU of the multi_tu test: a kernel that reads a table of this TU (its image's statics, at a different offset than
// scale.cpp's, so a kernel given the wrong image's statics reads the wrong values).
#include <sycl/sycl.hpp>

static const int k_pad[3] = {7, 7, 7};
static const int k_shift[4] = {10, 20, 30, 40};

void mt_shift(sycl::queue &q, int *x, int n) {
  q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) { x[i] = x[i] + k_shift[i % 4] + k_pad[i % 3] - 7; }).wait();
}
