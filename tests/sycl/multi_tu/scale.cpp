// One TU of the multi_tu test: a kernel that reads a table of this TU (its image's statics).
#include <sycl/sycl.hpp>

static const float k_scale[4] = {1.0f, 2.0f, 3.0f, 4.0f};

void mt_scale(sycl::queue &q, float *x, int n) {
  q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) { x[i] = x[i] * k_scale[i % 4]; }).wait();
}
