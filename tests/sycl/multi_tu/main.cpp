// The multi_tu test: kernels from three TUs (scale.cpp, shift.cpp and this one), each TU with its own device image, run in
// one program. Linked from objects, or with scale.cpp and shift.cpp in a shared library.
#include <sycl/sycl.hpp>
#include <cstdio>

void mt_scale(sycl::queue &q, float *x, int n);
void mt_shift(sycl::queue &q, int *x, int n);

int main() {
  sycl::queue q{sycl::gpu_selector_v};
  const int n = 1000;
  float *f = sycl::malloc_shared<float>(n, q);
  int *v = sycl::malloc_shared<int>(n, q);
  for (int i = 0; i < n; i++) { f[i] = (float)i; v[i] = i; }
  mt_scale(q, f, n);
  mt_shift(q, v, n);
  q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) { v[i] = v[i] * 2; }).wait();
  int bad = 0;
  const float scale[4] = {1.0f, 2.0f, 3.0f, 4.0f};
  const int shift[4] = {10, 20, 30, 40};
  for (int i = 0; i < n; i++) {
    bad += f[i] != (float)i * scale[i % 4];
    bad += v[i] != (i + shift[i % 4]) * 2;
  }
  printf("mismatches: %d of %d\n", bad, 2 * n);
  sycl::free(f, q);
  sycl::free(v, q);
  if (bad) return 1;
  printf("multi_tu ok\n");
  return 0;
}
