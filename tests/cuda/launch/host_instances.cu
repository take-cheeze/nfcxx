// Kernel instances that only the host compile knows, as in llama.cpp's binbcast.cu: launch_pack names
// k<op, T, type_for_index<const float *, I>...> as a value inside a template whose arguments are deduced (an
// index_sequence) or dependent (run_op's op), so the text gives no instance of it, and the rewriter made no device code.
// The driver now builds twice: the rewriter lists such kernels, the first host compile instantiates them, and the second
// device rewrite takes their instances from the object's symbols (nm -C). k also takes a function parameter pack, one
// pointer per extra source: each element is a parameter of the entry.
#include <cuda_runtime.h>
#include <stdio.h>
#include <utility>

template <typename T, size_t>
using type_for_index = T;

static __device__ float op_add(const float a, const float b) { return a + b; }
static __device__ float op_mul(const float a, const float b) { return a * b; }

template <float (*op)(const float, const float), typename T, typename... P>
static __global__ void k(const T *a, T *out, P... extra) {
  const int i = threadIdx.x;
  float v = (float)a[i];
  ((v = op(v, extra[i])), ...);
  out[i] = (T)v;
}

template <typename Kernel, typename... Args>
static void launch(Kernel kernel, Args... args) {
  kernel<<<1, 8>>>(args...);
}

template <float (*op)(const float, const float), typename T, size_t... I>
static void launch_pack(const T *a, T *out, const float *const *extra, std::index_sequence<I...>) {
  launch(k<op, T, type_for_index<const float *, I>...>, a, out, extra[I]...);
}

template <float (*op)(const float, const float)>
struct run_op {
  template <typename T>
  void operator()(const T *a, T *out, const float *const *extra, int n_extra) {
    if (n_extra == 1) launch_pack<op, T>(a, out, extra, std::make_index_sequence<1>());
    else launch_pack<op, T>(a, out, extra, std::make_index_sequence<2>());
  }
};

int main() {
  const int n = 8;
  float ha[n], hb[n], hc[n];
  for (int i = 0; i < n; i++) { ha[i] = 1.0f + i; hb[i] = 2.0f; hc[i] = 0.5f * i; }
  float *a, *b, *c, *out;
  cudaMalloc(&a, sizeof ha); cudaMalloc(&b, sizeof hb); cudaMalloc(&c, sizeof hc); cudaMalloc(&out, sizeof ha);
  cudaMemcpy(a, ha, sizeof ha, cudaMemcpyHostToDevice);
  cudaMemcpy(b, hb, sizeof hb, cudaMemcpyHostToDevice);
  cudaMemcpy(c, hc, sizeof hc, cudaMemcpyHostToDevice);
  const float *extra[2] = {b, c};
  float h[n];
  int bad = 0;
  run_op<op_add>()(a, out, extra, 1);
  cudaMemcpy(h, out, sizeof h, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) bad += h[i] != ha[i] + hb[i];
  run_op<op_add>()(a, out, extra, 2);
  cudaMemcpy(h, out, sizeof h, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) bad += h[i] != ha[i] + hb[i] + hc[i];
  run_op<op_mul>()(a, out, extra, 2);
  cudaMemcpy(h, out, sizeof h, cudaMemcpyDeviceToHost);
  for (int i = 0; i < n; i++) bad += h[i] != ha[i] * hb[i] * hc[i];
  printf("host instances: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
