// A class template with an alignas specifier (`struct alignas(sizeof(T) * 4) vec4`, as ggml-cuda's convert.cu has):
// the device unit must keep it, so the kernel's vec4<T> loads compile and run.
#include <cstdio>
#include <cuda_runtime.h>

template <typename T> struct alignas(sizeof(T) * 4) vec4 { T v[4]; };

template <typename T> __global__ void sum4(const T *x, T *y, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) {
    vec4<T> v = ((const vec4<T> *) x)[i];
    y[i] = v.v[0] + v.v[1] + v.v[2];
  }
}

int main() {
  const int n = 8;
  float h[4 * n], out[n];
  for (int i = 0; i < 4 * n; i++) h[i] = (float) (i % 7);
  float *dx, *dy;
  cudaMalloc(&dx, sizeof h);
  cudaMalloc(&dy, sizeof out);
  cudaMemcpy(dx, h, sizeof h, cudaMemcpyHostToDevice);
  sum4<float><<<1, 32>>>(dx, dy, n);
  cudaError_t e = cudaDeviceSynchronize();
  cudaMemcpy(out, dy, sizeof out, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) {
    float want = h[4 * i] + h[4 * i + 1] + h[4 * i + 2] + h[4 * i + 3];
    if (out[i] != want) bad++;
  }
  printf("vec4 alignas: %s, %d mismatches\n", cudaGetErrorString(e), bad);
  return 0;
}
