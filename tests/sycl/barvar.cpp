// A barrier in a loop whose bound is a captured variable: WGSL accepts it only because the closure is read from a uniform buffer.
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>
int main() {
  const int N = 256;
  std::vector<int> in(N, 1), out(N, 0);
  {
    sycl::queue q;
    sycl::buffer<int> A(in), O(out);
    int wgs = 64;                    // not a constant: captured by value
    q.submit([&](sycl::handler &h) {
      sycl::accessor a(A, h, sycl::read_only);
      sycl::accessor o(O, h, sycl::write_only, sycl::no_init);
      sycl::local_accessor<int, 1> s(sycl::range<1>(64), h);
      h.parallel_for(sycl::nd_range<1>(sycl::range<1>(N), sycl::range<1>(64)), [=](sycl::nd_item<1> it) {
        size_t l = it.get_local_id(0);
        s[l] = a[it.get_global_id(0)];
        for (int i = wgs / 2; i > 0; i >>= 1) {
          it.barrier(sycl::access::fence_space::local_space);
          if ((int)l < i) s[l] += s[l + i];
        }
        it.barrier(sycl::access::fence_space::local_space);
        o[it.get_global_id(0)] = s[0];
      });
    });
  }
  int bad = 0;
  for (int i = 0; i < N; i++) if (out[i] != 64) bad++;
  std::printf(bad ? "barvar FAIL %d\n" : "barvar ok\n", bad);
  return bad != 0;
}
