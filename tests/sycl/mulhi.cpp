// SYCL high word of a 64-bit product: out[i] = (uint32_t)(((uint64_t)a[i] * b) >> 32) with a dependent store after it. A 32-bit
// count shifts the 64-bit product here; the OpenCL device path must not drop the stores (scripts/pathb-spirv-emit.rb, the
// count takes the width of the value). Expected output: "mulhi ok".
#include <sycl/sycl.hpp>
#include <cstdint>
#include <cstdio>
#include <vector>

int main() {
  const int N = 256;
  const uint32_t b = 0x9E3779B9u;
  std::vector<uint32_t> a(N), out(N, 0xdeadbeefu), out2(N, 0xdeadbeefu);
  for (int i = 0; i < N; i++) a[i] = 0x01010101u * (uint32_t)(i + 1) + 0x80000000u;
  {
    sycl::queue q;
    sycl::buffer<uint32_t, 1> A(a.data(), sycl::range<1>(N)), O(out.data(), sycl::range<1>(N)),
        O2(out2.data(), sycl::range<1>(N));
    q.submit([&](sycl::handler &h) {
      sycl::accessor ra(A, h, sycl::read_only);
      sycl::accessor wo(O, h, sycl::write_only, sycl::no_init);
      sycl::accessor wo2(O2, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        uint32_t hi = (uint32_t)(((uint64_t)ra[i] * b) >> 32);
        wo[i] = hi;
        wo2[i] = hi ^ 0x5a5a5a5au;
      });
    });
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    uint32_t hi = (uint32_t)(((uint64_t)a[i] * b) >> 32);
    if (out[i] != hi || out2[i] != (hi ^ 0x5a5a5a5au)) {
      if (bad < 4) std::printf("i=%d out=%08x want=%08x out2=%08x\n", i, out[i], hi, out2[i]);
      bad++;
    }
  }
  std::printf(bad ? "mulhi FAIL %d\n" : "mulhi ok\n", bad);
  return bad != 0;
}
