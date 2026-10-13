// A tiled matrix multiply: 2-D nd_range, 2-D local_accessor tiles, barriers, float arithmetic.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <math.h>
#include <vector>

int main() {
  const int M = 48, K = 32, N = 64, T = 8;
  std::vector<float> a(M * K), b(K * N), c(M * N, 0.0f);
  for (int i = 0; i < M * K; i++) a[i] = (float)((i * 3) % 7) - 3.0f;
  for (int i = 0; i < K * N; i++) b[i] = (float)((i * 5) % 11) * 0.5f;
  {
    sycl::queue q;
    sycl::buffer<float, 2> A(a.data(), sycl::range<2>(M, K)), B(b.data(), sycl::range<2>(K, N)), C(c.data(), sycl::range<2>(M, N));
    q.submit([&](sycl::handler &h) {
      sycl::accessor ra(A, h, sycl::read_only);
      sycl::accessor rb(B, h, sycl::read_only);
      sycl::accessor wc(C, h, sycl::write_only, sycl::no_init);
      sycl::local_accessor<float, 2> ta(sycl::range<2>(T, T), h);
      sycl::local_accessor<float, 2> tb(sycl::range<2>(T, T), h);
      h.parallel_for(sycl::nd_range<2>(sycl::range<2>(M, N), sycl::range<2>(T, T)), [=](sycl::nd_item<2> it) {
        int row = (int)it.get_global_id(0), col = (int)it.get_global_id(1);
        int lr = (int)it.get_local_id(0), lc = (int)it.get_local_id(1);
        float acc = 0.0f;
        for (int t = 0; t < K / T; t++) {
          ta[sycl::id<2>(lr, lc)] = ra[sycl::id<2>(row, t * T + lc)];
          tb[sycl::id<2>(lr, lc)] = rb[sycl::id<2>(t * T + lr, col)];
          it.barrier(sycl::access::fence_space::local_space);
          for (int k = 0; k < T; k++) acc += ta[sycl::id<2>(lr, k)] * tb[sycl::id<2>(k, lc)];
          it.barrier(sycl::access::fence_space::local_space);
        }
        wc[sycl::id<2>(row, col)] = acc;
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < M; i++)
    for (int j = 0; j < N; j++) {
      float s = 0.0f;
      for (int k = 0; k < K; k++) s += a[i * K + k] * b[k * N + j];
      if (::fabsf(s - c[i * N + j]) > 1e-3f) bad++;
    }
  std::printf(bad ? "matmul FAIL %d\n" : "matmul ok\n", bad);
  return bad != 0;
}
