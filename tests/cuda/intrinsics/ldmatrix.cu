// ldmatrix as llama.cpp's mma.cuh writes it: inline asm with no state space, so its "l" operand is a generic pointer
// to shared memory, passed as it is (nvcc does not convert it). x4: thread t gets in register j the 32-bit word t % 4
// of the row whose address thread 8 * j + t / 4 gives. Each thread gives a row of a 16 x 8 int tile, as load_ldmatrix
// does for tile<16, 8, int>, with a padded stride. sm_75 and later.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void k(int *out) {
  extern __shared__ int tile[];
  const int stride = 12;
  for (int i = threadIdx.x; i < 16 * stride; i += 32) tile[i] = i * 7 + 3;
  __syncwarp();
  const int *xs = tile + (threadIdx.x % 16) * stride + (threadIdx.x / 16) * 4;
  int x[4] = {0, 0, 0, 0};
#ifdef __CUDA_ARCH__   // as mma.cuh: the host copy of the kernel has no PTX
  asm volatile("ldmatrix.sync.aligned.m8n8.x4.b16 {%0, %1, %2, %3}, [%4];"
               : "=r"(x[0]), "=r"(x[1]), "=r"(x[2]), "=r"(x[3])
               : "l"(xs));
#endif
  for (int j = 0; j < 4; j++) out[threadIdx.x * 4 + j] = x[j];
}

int main() {
  int *d, h[128];
  cudaMalloc(&d, sizeof h);
  k<<<1, 32, 16 * 12 * sizeof(int)>>>(d);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int t = 0; t < 32; t++) {
    for (int j = 0; j < 4; j++) {
      const int src = 8 * j + t / 4;   // the thread whose pointer gives the row
      const int word = (src % 16) * 12 + (src / 16) * 4 + t % 4;
      bad += h[t * 4 + j] != word * 7 + 3;
    }
  }
  printf("ldmatrix: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
