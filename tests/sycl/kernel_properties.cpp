// parallel_for with a kernel-property list (sycl_ext_oneapi_kernel_properties): ggml-sycl's flash-attention vector kernel
// (fattn-common.hpp) passes properties{ grf_size_automatic } when it wants the large register file. The shim's properties
// change nothing; the kernel runs as it would without them. Expected output: "kernel_properties ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/intel/experimental/grf_size_properties.hpp>
#include <cstdio>

int main() {
  sycl::queue q;
  const int n = 64;
  int *a = sycl::malloc_shared<int>(n, q);
  for (int i = 0; i < n; i++) a[i] = i;
  q.submit([&](sycl::handler &h) {
    h.parallel_for(sycl::nd_range<1>(n, 16),
                   sycl::ext::oneapi::experimental::properties{sycl::ext::intel::experimental::grf_size_automatic},
                   [=](sycl::nd_item<1> it) { a[it.get_global_id(0)] *= 3; });
  }).wait();
  q.submit([&](sycl::handler &h) {
    h.parallel_for(sycl::range<1>(n), sycl::ext::oneapi::experimental::properties{},
                   [=](sycl::id<1> i) { a[i] += 1; });
  }).wait();
  int bad = 0;
  for (int i = 0; i < n; i++) if (a[i] != i * 3 + 1) bad++;
  sycl::free(a, q);
  if (bad) { std::printf("kernel_properties: %d wrong\n", bad); return 1; }
  std::printf("kernel_properties ok\n");
  return 0;
}
