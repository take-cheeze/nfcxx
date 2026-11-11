// sycl::half2 (the ggml shim in lib/sycl-ggml/sycl/half_type.hpp) with the operators the ggml-sycl dequantize and mul_mat
// kernels use: component-wise + - * / on half2 and with a half scalar, unary minus, compound assignment, s0/s1 as lvalues,
// fma on half2, and convert<float>() to vec<float, 2>. The operands and results are small exact binary16 values, so the
// device result must equal the float reference exactly. Expected output: "half2_ops ok".
#include <sycl/sycl.hpp>
#include "../../lib/sycl-ggml/sycl/half_type.hpp"
#include <cstdio>

constexpr int K = 10;  // results per lane

// one lane i: the ten results of (a[i], b[i]), written to out[i*K .. i*K+K)
static void half2_case(const sycl::half2 * a, const sycl::half2 * b, float * out, int i) {
  float * o = out + i * K;
  sycl::half2 x = a[i], y = b[i];
  sycl::half2 r0 = x * y;
  sycl::half2 r1 = x + y;
  sycl::half2 r2 = x - y;
  sycl::half2 r3 = x / y;
  sycl::half2 r4 = x * sycl::half(2.0f);                // half2 times a scalar
  sycl::half2 r5 = sycl::half(1.0f) - x;                // scalar minus half2
  sycl::half2 r6 = -x;
  sycl::half2 r7 = sycl::fma(x, y, r4);
  sycl::half2 c = x;
  c *= y;                                              // compound assignment, then s0/s1 as lvalues
  c.s1() += sycl::half(0.5f);
  c.s0() /= sycl::half(2.0f);
  sycl::vec<float, 2> f = y.convert<float>();          // convert to vec<float, 2>
  o[0] = (float) r0.s0(); o[1] = (float) r0.s1();
  o[2] = (float) r1.s0(); o[3] = (float) r2.s1();
  o[4] = (float) r3.s0(); o[5] = (float) r4.s1();
  o[6] = (float) r5.s0(); o[7] = (float) r6.s1();
  o[8] = (float) r7.s0();
  o[9] = f[0] + f[1] + (float) c.s1();
}

int main() {
  const int N = 4;
  // operands: (x.s0, x.s1) and (y.s0, y.s1) per lane, all exact in binary16 with exact products and quotients
  const float ax[N][2] = { { 1.5f, -2.0f }, { 3.0f, 0.5f }, { -2.0f, 4.0f }, { 0.5f, 1.5f } };
  const float ay[N][2] = { { 2.0f, 4.0f }, { -0.5f, 8.0f }, { 4.0f, -0.5f }, { -0.5f, 8.0f } };
  sycl::queue q;
  sycl::half2 * a = sycl::malloc_shared<sycl::half2>(N, q);
  sycl::half2 * b = sycl::malloc_shared<sycl::half2>(N, q);
  float *       out = sycl::malloc_shared<float>(N * K, q);
  for (int i = 0; i < N; i++) {
    a[i] = sycl::half2(sycl::half(ax[i][0]), sycl::half(ax[i][1]));
    b[i] = sycl::half2(sycl::half(ay[i][0]), sycl::half(ay[i][1]));
  }
  q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { half2_case(a, b, out, (int) i[0]); }).wait();

  int bad = 0;
  for (int i = 0; i < N; i++) {
    const float x0 = ax[i][0], x1 = ax[i][1], y0 = ay[i][0], y1 = ay[i][1];
    // the references: r0..r7 component 0 or 1 as in the case, then the convert and compound results
    const float want[K] = {
      x0 * y0, x1 * y1,                 // r0
      x0 + y0, x1 - y1,                 // r1 s0, r2 s1
      x0 / y0, x1 * 2.0f,               // r3 s0, r4 s1
      1.0f - x0, -x1,                   // r5 s0, r6 s1
      x0 * y0 + x0 * 2.0f,              // r7 s0 = fma(x, y, 2x)
      y0 + y1 + (x1 * y1 + 0.5f),       // convert sum plus c.s1 = x1*y1 + 0.5
    };
    for (int k = 0; k < K; k++) {
      if (out[i * K + k] != want[k]) {
        bad++;
        std::printf("lane %d op %d: got %g want %g\n", i, k, out[i * K + k], want[k]);
      }
    }
  }
  if (bad == 0) std::printf("half2_ops ok\n");
  else std::printf("half2_ops FAIL %d\n", bad);
  return bad != 0;
}
