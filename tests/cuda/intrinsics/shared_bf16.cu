// Two things ggml-cuda's mmq and mma units need on the device: a static __shared__ array that has the same name as a
// dynamic one in another kernel (each kernel's uses are its own: the static one shadows the dynamic name in its block),
// and nv_bfloat162 as a two-lane struct (brace-initialized arrays of it, as in mma.cuh's tiles). Expected values are
// what CUDA computes for these inputs.
#include <cuda_runtime.h>
#include <cuda_bf16.h>
#include <stdio.h>

// A dynamic array `ids` (the launch gives its bytes).
__global__ void dyn(int *out, int n) {
  extern __shared__ int ids[];
  for (int i = threadIdx.x; i < n; i += blockDim.x) ids[i] = i * 3;
  __syncthreads();
  out[threadIdx.x] = ids[threadIdx.x];
}

// A static array with the same name: its uses are not the dynamic array's.
__global__ void stat(int *out) {
  __shared__ int ids[4];
  ids[threadIdx.x] = 100 + threadIdx.x;
  __syncthreads();
  out[threadIdx.x] = ids[threadIdx.x];
}

// The bf16 pair as two lanes: an array brace-initialized with a float pair, then the lanes written and read back.
__global__ void bf(unsigned *out) {
  __nv_bfloat162 x[2] = {{0.0f, 0.0f}};
  unsigned v = 0xc0003f80u;  // lane x = 1.0 (0x3f80), lane y = -2.0 (0xc000)
  x[1] = *reinterpret_cast<const __nv_bfloat162 *>(&v);
  out[0] = *reinterpret_cast<const unsigned *>(&x[0]);
  out[1] = *reinterpret_cast<const unsigned *>(&x[1]);
}

int main() {
  int *dout;
  unsigned *dbf;
  cudaMalloc((void **)&dout, 8 * sizeof(int));
  cudaMalloc((void **)&dbf, 2 * sizeof(unsigned));
  dyn<<<1, 4, 8 * sizeof(int)>>>(dout, 8);
  int d[4];
  cudaMemcpy(d, dout, sizeof d, cudaMemcpyDeviceToHost);
  int bad = 0;
  // ids[t] = 3 * t for t < 8, read back by thread t < 4: 0, 3, 6, 9.
  bad += d[0] != 0;
  bad += d[1] != 3;
  bad += d[2] != 6;
  bad += d[3] != 9;
  stat<<<1, 4>>>(dout);
  cudaMemcpy(d, dout, sizeof d, cudaMemcpyDeviceToHost);
  bad += d[0] != 100;
  bad += d[1] != 101;
  bad += d[2] != 102;
  bad += d[3] != 103;
  bf<<<1, 1>>>(dbf);
  unsigned o[2];
  cudaMemcpy(o, dbf, sizeof o, cudaMemcpyDeviceToHost);
  // x[0] = (0.0, 0.0) -> 0x00000000; x[1] = (1.0, -2.0) -> bf16 0x3f80 (low), 0xc000 (high) = 0xc0003f80.
  bad += o[0] != 0u;
  bad += o[1] != 0xc0003f80u;
  printf("shared bf16: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
  return bad != 0;
}
