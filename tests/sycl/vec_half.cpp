// sycl::vec<sycl::half, 1> in a device function (the F16 arm of llama.cpp's ggml-sycl softmax.cpp, t2f32<sycl::half>).
// The vec(T) constructor default-initialises its storage T v_[N]; with a non-trivial half default constructor the device
// pass emitted a constructor call through a function pointer and refused it. Expected output: "vec_half ok".
#include <sycl/sycl.hpp>
#include "../../lib/sycl-ggml/sycl/half_type.hpp"
#include <cstdio>

template <typename T> static float t2f32(T val) { return (float)val; }
template <> float t2f32<sycl::half>(sycl::half val) {
  sycl::vec<sycl::half, 1> v(val);
  return (float)v[0];
}

int main() {
  const int N = 4;
  const float in[N] = {0.5f, -2.0f, 3.25f, 100.0f};  // exact in binary16
  sycl::queue q;
  float * d = sycl::malloc_shared<float>(N, q);
  sycl::half * h = sycl::malloc_shared<sycl::half>(N, q);
  for (int i = 0; i < N; i++) { h[i] = sycl::half(in[i]); d[i] = -1.0f; }
  q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { d[i] = t2f32(h[i]); }).wait();
  int bad = 0;
  for (int i = 0; i < N; i++)
    if (d[i] != in[i]) bad++;
  std::printf(bad ? "vec_half FAIL %d\n" : "vec_half ok\n", bad);
  return bad != 0;
}
