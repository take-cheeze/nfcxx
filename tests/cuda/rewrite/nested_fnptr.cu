// A dispatch template takes a function pointer as a template argument and launches a kernel with it (set-rows.cu's
// set_rows_cuda_quant shape): the function name passed from the call reaches the nested launch, and the instance's
// block type is the one the call gives.
#include <cuda_runtime.h>
#include <stdio.h>

typedef struct { int q; } blk;

__device__ void quant_a(const float *x, blk *y) { y->q = (int)(x[0] * 2.0f); }

template <typename idx_t, typename block_type, int qk, void (*quantize_func)(const float *, block_type *)>
static __global__ void k_rows(const float *src, block_type *dst, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) quantize_func(src + i * qk, dst + i);
}

template <typename idx_t, typename block_type, int qk, void (*quantize_func)(const float *, block_type *)>
static void rows_cuda(const float *src, block_type *dst, int n, cudaStream_t stream) {
  k_rows<idx_t, block_type, qk, quantize_func><<<(n + 31) / 32, 32, 0, stream>>>(src, dst, n);
}

int main() {
  const int n = 8;
  float hx[n] = {1, 2, 3, 4, 5, 6, 7, 8};
  float *x;
  blk *y;
  cudaMalloc((void **)&x, sizeof(hx));
  cudaMalloc((void **)&y, n * sizeof(blk));
  cudaMemcpy(x, hx, sizeof(hx), cudaMemcpyHostToDevice);
  rows_cuda<int, blk, 1, quant_a>(x, y, n, 0);
  cudaDeviceSynchronize();
  blk r[n];
  cudaMemcpy(r, y, sizeof(r), cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++)
    if (r[i].q != (int)(hx[i] * 2.0f)) bad++;
  printf("nested fnptr: %d mismatches\n", bad);
  cudaFree(x);
  cudaFree(y);
  return bad != 0;
}
