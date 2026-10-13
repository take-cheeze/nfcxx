// nd_range with work-group memory, barriers and an atomic: a sum reduction.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  const int N = 4096, WG = 64;
  std::vector<int> in(N);
  long expect = 0;
  for (int i = 0; i < N; i++) { in[i] = (i * 7) % 13 - 5; expect += in[i]; }
  int total = 0;
  std::vector<int> per(N / WG, 0);
  {
    sycl::queue q;
    sycl::buffer<int> A(in), T(&total, sycl::range<1>(1)), P(per);
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(A, h, sycl::read_only);
      sycl::accessor t(T, h, sycl::read_write);
      sycl::accessor p(P, h, sycl::write_only, sycl::no_init);
      sycl::local_accessor<int, 1> tmp(sycl::range<1>(WG), h);
      h.parallel_for(sycl::nd_range<1>(sycl::range<1>(N), sycl::range<1>(WG)), [=](sycl::nd_item<1> it) {
        size_t l = it.get_local_id(0);
        tmp[l] = a[it.get_global_id(0)];
        it.barrier(sycl::access::fence_space::local_space);
        for (size_t s = WG / 2; s > 0; s >>= 1) {
          if (l < s) tmp[l] += tmp[l + s];
          it.barrier(sycl::access::fence_space::local_space);
        }
        if (l == 0) {
          p[it.get_group(0)] = tmp[0];
          sycl::atomic_ref<int> r(t[0]);
          r.fetch_add(tmp[0]);
        }
      });
    });
  }
  int bad = (long)total != expect;
  for (int g = 0; g < N / WG; g++) {
    int s = 0;
    for (int i = 0; i < WG; i++) s += in[g * WG + i];
    if (per[g] != s) bad++;
  }
  std::printf(bad ? "reduce FAIL total %d want %ld\n" : "reduce ok\n", total, expect);
  return bad != 0;
}
