// A generic lambda with no captures (an empty closure object) handed through two levels of templates and captured by value
// into a kernel, the shape of ggml_sycl_op_sgn's [](auto x) { return op_sgn(x); } through ggml_sycl_op_unary.
// Expected output: "static_closure ok".
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

template <typename T>
static T op_sgn(T x) {
  return x > static_cast<T>(0) ? static_cast<T>(1) : (x < static_cast<T>(0) ? static_cast<T>(-1) : static_cast<T>(0));
}

template <typename T, typename F>
static void unary_kernel(const T *x, T *dst, int k, sycl::nd_item<1> item, F func) {
  for (int i = item.get_global_id(0); i < k; i += item.get_global_range(0)) dst[i] = func(x[i]);
}

template <typename F>
static void unary_op(sycl::queue &q, const float *src, float *dst, int n, F func) {
  q.submit([&](sycl::handler &h) {
    h.parallel_for(sycl::nd_range<1>(sycl::range<1>(128), sycl::range<1>(64)), [=](sycl::nd_item<1> item) {
      unary_kernel(src, dst, n, item, func);
    });
  });
  q.wait();
}

int main() {
  const int N = 64;
  std::vector<float> x(N), r(N, -7.0f);
  for (int i = 0; i < N; i++) x[i] = (float)(i % 5) - 2.0f;
  sycl::queue q;
  {
    auto *src = sycl::malloc_shared<float>(N, q);
    auto *dst = sycl::malloc_shared<float>(N, q);
    for (int i = 0; i < N; i++) src[i] = x[i];
    unary_op(q, src, dst, N, [](auto v) { return op_sgn(v); });
    for (int i = 0; i < N; i++) r[i] = dst[i];
    sycl::free(src, q);
    sycl::free(dst, q);
  }
  int bad = 0;
  for (int i = 0; i < N; i++)
    if (r[i] != (x[i] > 0.0f ? 1.0f : (x[i] < 0.0f ? -1.0f : 0.0f))) bad++;
  std::printf(bad ? "static_closure FAIL %d\n" : "static_closure ok\n", bad);
  return bad != 0;
}
