// A 16x16x16 f16 matmul on one warp with the tensor-core instruction of llama.cpp's mma.cuh (the m16n8k8 f16 form,
// f32 accumulate). A and B hold small integers, so every value is exact. The fragment layout is the PTX one:
// with g = lane / 4 and t = lane % 4, a0/a1 hold A[g][2t..2t+1] and A[g+8][2t..2t+1] (two halves per register, the
// lower index in the low half); b0 holds B[2t..2t+1][g]; c0..c3 are C[g][2t], C[g][2t+1], C[g+8][2t], C[g+8][2t+1].
#include <cuda_runtime.h>
#include <stdio.h>

#ifdef __CUDA_ARCH__
#define MMA_M16N8K8_F16(d0, d1, d2, d3, a0, a1, b0)                                             \
  asm("mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32 {%0, %1, %2, %3}, {%4, %5}, {%6}, {%0, %1, %2, %3};" \
      : "+f"(d0), "+f"(d1), "+f"(d2), "+f"(d3)                                                  \
      : "r"(a0), "r"(a1), "r"(b0))
#endif

__device__ unsigned pack2(unsigned short lo, unsigned short hi) { return lo | ((unsigned)hi << 16); }

__global__ void mma16(const unsigned short *A, const unsigned short *B, float *C) {
  int lane = threadIdx.x;
  int g = lane >> 2, t = lane & 3;
  for (int nt = 0; nt < 2; nt++) {
    float d0 = 0.0f, d1 = 0.0f, d2 = 0.0f, d3 = 0.0f;
    for (int ks = 0; ks < 2; ks++) {
      int k0 = ks * 8;
      unsigned a0 = pack2(A[g * 16 + k0 + 2 * t], A[g * 16 + k0 + 2 * t + 1]);
      unsigned a1 = pack2(A[(g + 8) * 16 + k0 + 2 * t], A[(g + 8) * 16 + k0 + 2 * t + 1]);
      unsigned b0 = pack2(B[(k0 + 2 * t) * 16 + nt * 8 + g], B[(k0 + 2 * t + 1) * 16 + nt * 8 + g]);
#ifdef __CUDA_ARCH__
      MMA_M16N8K8_F16(d0, d1, d2, d3, a0, a1, b0);
#endif
    }
    C[g * 16 + nt * 8 + 2 * t] = d0;
    C[g * 16 + nt * 8 + 2 * t + 1] = d1;
    C[(g + 8) * 16 + nt * 8 + 2 * t] = d2;
    C[(g + 8) * 16 + nt * 8 + 2 * t + 1] = d3;
  }
}

// IEEE binary16 bits of the small integers used here.
static unsigned short half_bits(int v) {
  switch (v) {
    case 0: return 0x0000;
    case 1: return 0x3C00;
    case 2: return 0x4000;
    case -1: return 0xBC00;
    default: return 0xC000; /* -2 */
  }
}

int main() {
  unsigned short hA[256], hB[256];
  float ref[256], hC[256];
  unsigned seed = 12345;
  int va[256], vb[256];
  for (int i = 0; i < 256; i++) {
    seed = seed * 1103515245u + 12345u;
    va[i] = (int)((seed >> 16) % 5) - 2;
    seed = seed * 1103515245u + 12345u;
    vb[i] = (int)((seed >> 16) % 5) - 2;
    hA[i] = half_bits(va[i]);
    hB[i] = half_bits(vb[i]);
  }
  for (int r = 0; r < 16; r++)
    for (int c = 0; c < 16; c++) {
      float s = 0.0f;
      for (int k = 0; k < 16; k++) s += (float)va[r * 16 + k] * (float)vb[k * 16 + c];
      ref[r * 16 + c] = s;
    }
  unsigned short *dA, *dB;
  float *dC;
  cudaMalloc((void **)&dA, sizeof hA);
  cudaMalloc((void **)&dB, sizeof hB);
  cudaMalloc((void **)&dC, sizeof hC);
  cudaMemcpy(dA, hA, sizeof hA, cudaMemcpyHostToDevice);
  cudaMemcpy(dB, hB, sizeof hB, cudaMemcpyHostToDevice);
  mma16<<<1, 32>>>(dA, dB, dC);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(hC, dC, sizeof hC, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 256; i++) bad += hC[i] != ref[i];
  printf("mma: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(dA);
  cudaFree(dB);
  cudaFree(dC);
  return bad != 0 || err != cudaSuccess;
}
