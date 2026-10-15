#include <cuda_runtime.h>
template <typename T> __global__ void scale_tk(T *p, int n, T k) { int i = blockIdx.x * blockDim.x + threadIdx.x; if (i < n) p[i] = p[i] * k; }
__global__ void kshared(float *p, int n) { int i = blockIdx.x * blockDim.x + threadIdx.x; if (i < n) p[i] = p[i] + 2000.0f; }
__global__ void kB(float *p, int n) { int i = blockIdx.x * blockDim.x + threadIdx.x; if (i < n) p[i] = p[i] - 5.0f; }
extern "C" void runB(float *d, int n) {
  kB<<<(n + 127) / 128, 128>>>(d, n); kshared<<<(n + 127) / 128, 128>>>(d, n);
  scale_tk<float><<<(n + 127) / 128, 128>>>(d, n, 3.0f);
}
