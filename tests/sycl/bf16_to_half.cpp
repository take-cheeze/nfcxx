// A bfloat16 assigned to a half in a kernel (ggml-sycl's dmmv.cpp convert_bf16: `v.x() = x[i]` with dfloat2 = half2 and x a
// bfloat16 array). The value goes through float. Expected output: "bf16_to_half ok".
#include <sycl/sycl.hpp>
#include "../../lib/sycl-ggml/sycl/half_type.hpp"
#include <cstdio>

int main() {
  sycl::queue q;
  const int n = 32;
  sycl::ext::oneapi::bfloat16 *x = sycl::malloc_shared<sycl::ext::oneapi::bfloat16>(n, q);
  sycl::half *h = sycl::malloc_shared<sycl::half>(n, q);
  for (int i = 0; i < n; i++) x[i] = 0.25f * i - 3.0f;
  q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) {
    sycl::half v;
    v = x[i];
    h[i] = v;
  }).wait();
  int bad = 0;
  for (int i = 0; i < n; i++) if ((float)h[i] != 0.25f * i - 3.0f) bad++;
  sycl::free(x, q);
  sycl::free(h, q);
  if (bad) { std::printf("bf16_to_half: %d wrong\n", bad); return 1; }
  std::printf("bf16_to_half ok\n");
  return 0;
}
