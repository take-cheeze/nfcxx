// Back-to-back small dispatches on OpenCL and Level Zero stay cheap with the default 1 GB heap. The runtimes kept the words
// the host writes and reads on every dispatch (the flag, the captured state, the push block) in the shared heap, and the
// driver migrates a shared allocation as a whole when the host touches it: each dispatch moved the heap to the host and
// back, 400 ms with 1 GB whatever the kernel (ggml-sycl's argsort of 131072 elements, 153 passes, took two minutes). They
// are in a host allocation now, with the kernels marked for indirect access; a dispatch here is about 0.1 ms. The bound
// (50 ms on average) is far from both.
#include <sycl/sycl.hpp>
#include <chrono>
#include <cstdio>

int main() {
  sycl::queue q;
  const size_t n = 16384;
  const int reps = 20;
  int *a = sycl::malloc_shared<int>(n, q);
  for (size_t i = 0; i < n; i++) a[i] = (int)i;
  q.parallel_for(sycl::nd_range<1>(n, 256), [=](sycl::nd_item<1> it) { a[it.get_global_id(0)] += 1; }).wait();   // builds the module
  auto t0 = std::chrono::steady_clock::now();
  for (int r = 0; r < reps; r++)
    q.parallel_for(sycl::nd_range<1>(n, 256), [=](sycl::nd_item<1> it) { a[it.get_global_id(0)] += 1; });
  q.wait();
  const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / reps;
  long bad = 0;
  for (size_t i = 0; i < n; i++) bad += a[i] != (int)i + 1 + reps;
  sycl::free(a, q);
  if (bad || ms > 50.0) { std::printf("dispatch_cost: %.3f ms per dispatch, %ld wrong\n", ms, bad); return 1; }
  std::printf("dispatch_cost ok\n");
  return 0;
}
