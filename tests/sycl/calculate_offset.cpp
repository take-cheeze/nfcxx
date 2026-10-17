// calculate_offset with brace-initialised int64 values for an std::array<int, N> parameter, the shape of ggml-sycl's
// norm.cpp (calculate_offset<3>({int64 strides...}, {int indices...})). g++ accepts it with -Wnarrowing; the front end must
// too, and the overload must not be rejected. Expected output: "calculate_offset ok".
#include <sycl/sycl.hpp>
#include <array>
#include <cstdint>
#include <cstdio>
#include <vector>

template <int N>
inline size_t calculate_offset(const std::array<int, N> &strides, const std::array<int, N> &indices) {
  size_t offset = 0;
  for (int i = 0; i < N; i++) offset += strides[i] * indices[i];
  return offset;
}

int main() {
  const int N = 8;
  // not constants: a narrowing conversion of a constant that fits is no narrowing, and norm.cpp's strides are run-time values
  int64_t s0 = 12, s1 = 4, s2 = 1;
  std::vector<int> out(N, -1);
  {
    sycl::queue q;
    sycl::buffer<int, 1> O(out.data(), sycl::range<1>(N));
    q.submit([&](sycl::handler &h) {
      sycl::accessor wo(O, h, sycl::write_only, sycl::no_init);
      h.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        const int a = i[0] & 1, b = (i[0] >> 1) & 1;
        wo[i] = (int)calculate_offset<3>({s0, s1, s2}, {a, b, 1});
      });
    });
    q.wait();
  }
  int bad = 0;
  for (int i = 0; i < N; i++) {
    const int a = i & 1, b = (i >> 1) & 1;
    if (out[i] != 12 * a + 4 * b + 1) bad++;
  }
  std::printf(bad ? "calculate_offset FAIL %d\n" : "calculate_offset ok\n", bad);
  return bad != 0;
}
