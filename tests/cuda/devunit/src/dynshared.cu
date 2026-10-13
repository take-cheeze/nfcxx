// Dynamic shared memory used the way llama.cpp's mmq.cuh uses it: a template device function declares
// `extern __shared__ int buf[]` and uses it bare (`buf + J`, passed on to a call) and subscripted. A kernel in the
// same file declares a static `__shared__ int buf[32]` of the same name, which keeps its own meaning. main checks
// both on the GPU.
#include <cuda_runtime.h>
#include <stdio.h>

__device__ int at(int *p, int i) { return p[i]; }

template <int J>
__device__ void dyn_body(int *out) {
  extern __shared__ int buf[];
  int *tile = buf + J;
  tile[threadIdx.x] = (int)threadIdx.x + J;
  buf[threadIdx.x] = (int)threadIdx.x * 2;   // below J, so it does not alias the tile
  __syncthreads();
  out[threadIdx.x] = at(buf + J, threadIdx.x) + buf[threadIdx.x];
}

__global__ void dyn_kernel(int *out) { dyn_body<32>(out); }

__global__ void static_kernel(int *out) {
  __shared__ int buf[32];
  buf[threadIdx.x] = 7;
  __syncthreads();
  out[32 + threadIdx.x] = buf[threadIdx.x];
}

int main() {
  int *d = 0, h[64];
  cudaMalloc((void **)&d, sizeof h);
  dyn_kernel<<<1, 32, (32 + 32) * sizeof(int)>>>(d);
  static_kernel<<<1, 32>>>(d);
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int t = 0; t < 32; t++) {
    bad += h[t] != (t + 32) + t * 2;   // the tile is buf[32 + t] = t + 32; buf[t] = 2t: the two do not overlap
    bad += h[32 + t] != 7;
  }
  printf("dynshared: %d mismatches\n", bad);
  cudaFree(d);
  return bad != 0;
}
