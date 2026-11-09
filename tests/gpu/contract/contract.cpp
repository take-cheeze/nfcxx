// The float operations of a SYCL kernel round one by one, as the source says: a*b - c*d and a*b + c are each computed with
// a rounded product. A device compiler may fuse the product into the add or subtract (a fused multiply-add rounds once), which
// differs from the source by an ulp. The SPIR-V emitter marks the OpenCL kernel ContractionOff (tools/pathb-spirv-emit), and
// this test checks the device results bit for bit against the host's two-rounding values (the host is compiled without
// FMA contraction: the default x86-64 target has none). Output: "mismatches: N of M" (N must be 0), and the device name.
#include <sycl/sycl.hpp>

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

uint32_t bits(float f) {
  uint32_t u;
  std::memcpy(&u, &f, 4);
  return u;
}

// A normal float with a random sign, an exponent in [-4, 4] and a random 23-bit fraction: its products have full
// significands, so a fused and a rounded product differ often.
float operand(uint32_t &state) {
  state = state * 1664525u + 1013904223u;
  const uint32_t sign = state & 0x80000000u;
  const uint32_t expo = (127 - 4 + (state >> 24) % 9) << 23;
  const uint32_t frac = (state >> 1) & 0x7fffffu;
  const uint32_t u = sign | expo | frac;
  float f;
  std::memcpy(&f, &u, 4);
  return f;
}

}  // namespace

int main() {
  constexpr int N = 1 << 20;
  sycl::queue q;
  std::printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());
  float *a = sycl::malloc_shared<float>(N, q), *b = sycl::malloc_shared<float>(N, q);
  float *c = sycl::malloc_shared<float>(N, q), *d = sycl::malloc_shared<float>(N, q);
  float *r1 = sycl::malloc_shared<float>(N, q), *r2 = sycl::malloc_shared<float>(N, q);
  uint32_t state = 12345;
  for (int i = 0; i < N; i++) {
    a[i] = operand(state);
    b[i] = operand(state);
    c[i] = operand(state);
    d[i] = operand(state);
  }
  q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> id) {
    const int i = (int)id[0];
    const float p = a[i] * b[i];
    const float s = c[i] * d[i];
    r1[i] = p - s;
    r2[i] = p + c[i];
  }).wait();
  int bad = 0;
  for (int i = 0; i < N; i++) {
    const float p = a[i] * b[i];
    const float s = c[i] * d[i];
    const float w1 = p - s;
    const float w2 = p + c[i];
    if (bits(w1) != bits(r1[i]) || bits(w2) != bits(r2[i])) {
      if (bad < 5) std::printf("i=%d: r1 %a want %a, r2 %a want %a\n", i, r1[i], w1, r2[i], w2);
      bad++;
    }
  }
  std::printf("mismatches: %d of %d\n", bad, N);
  return bad != 0;
}
