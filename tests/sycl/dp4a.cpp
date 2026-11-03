// dpct::dp4a(int, int, int), llama.cpp's SYCL helper for the signed 8-bit dot product, with the same signature so the device
// pass names it _ZN4dpct4dp4aIiiiEEDaT_T0_T1_: the emitter lowers that call to the packed integer dot product (OpSDot). The
// scalar body is the reference. Expected output: "dp4a ok".
#include <sycl/sycl.hpp>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace dpct {
template <class T1, class T2, class T3> auto dp4a(T1 a, T2 b, T3 c) {
  int res = c;
  for (int k = 0; k < 4; k++) res += (int)(int8_t)(a >> (8 * k)) * (int)(int8_t)(b >> (8 * k));
  return res;
}
}  // namespace dpct

int main() {
  const int N = 4096;
  std::vector<int> a(N), b(N), c(N), out(N, 0), ref(N);
  uint32_t s = 12345;
  auto next = [&s]() { s = s * 1664525u + 1013904223u; return (int)s; };
  for (int i = 0; i < N; i++) {
    a[i] = next();
    b[i] = next();
    c[i] = i % 7 == 0 ? 0x7fffffff : next();   // the sum wraps: both sides wrap the same way
    ref[i] = (int)dpct::dp4a(a[i], b[i], c[i]);
  }
  {
    sycl::queue q;
    sycl::buffer<int, 1> A(a.data(), sycl::range<1>(N)), B(b.data(), sycl::range<1>(N)), C(c.data(), sycl::range<1>(N));
    sycl::buffer<int, 1> O(out.data(), sycl::range<1>(N));
    q.submit([&](sycl::handler &h) {
      sycl::accessor ra(A, h, sycl::read_only);
      sycl::accessor rb(B, h, sycl::read_only);
      sycl::accessor rc(C, h, sycl::read_only);
      sycl::accessor wo(O, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { wo[i] = dpct::dp4a(ra[i], rb[i], rc[i]); });
    });
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N; i++)
    if (out[i] != ref[i]) bad++;
  std::printf(bad ? "dp4a FAIL %d\n" : "dp4a ok\n", bad);
  return bad != 0;
}
