// The nvcuda::wmma API for the m8n32k16 shape (f16 A row-major and B col-major, f32 accumulate), as lightning-indexer.cu
// uses it: fragments in shared memory, load_matrix_sync, fill_fragment, mma_sync, store_matrix_sync with mem_row_major.
// The inputs are small integers, so the host reference is exact. A mutant that loads B row-major must change the result.
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef __CUDA_ARCH__
#include <mma.h>
using namespace nvcuda;
#endif

__global__ void wmma_api(const unsigned short *A, const unsigned short *B, float *D) {
#ifdef __CUDA_ARCH__
  __shared__ half sa[8 * 16], sb[16 * 32];
  __shared__ float sd[8 * 32];
  int t = threadIdx.x;
  for (int i = t; i < 8 * 16; i += 32) sa[i] = *(const half *)&A[i];
  for (int i = t; i < 16 * 32; i += 32) sb[i] = *(const half *)&B[i];
  __syncwarp();
  wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> fa;
  wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::col_major> fb;
  wmma::fragment<wmma::accumulator, 8, 32, 16, float> fc;
  wmma::load_matrix_sync(fa, sa, 16);
  wmma::load_matrix_sync(fb, sb, 16);
  wmma::fill_fragment(fc, 0.0f);
  wmma::mma_sync(fc, fa, fb, fc);
  wmma::store_matrix_sync(sd, fc, 32, wmma::mem_row_major);
  __syncwarp();
  for (int i = t; i < 8 * 32; i += 32) D[i] = sd[i];
#endif
}

static unsigned short half_of(int v) {  // small integers as f16 bit patterns (exact for |v| <= 4)
  unsigned short h = 0;
  if (v == 0) return 0;
  int sign = v < 0; unsigned m = sign ? -v : v; int e = 0;
  while ((m >> e) > 1) e++;
  unsigned frac = ((m << 10) >> e) & 0x3ff;
  return (unsigned short)((sign << 15) | ((e + 15) << 10) | frac);
}

int main() {
  unsigned short hA[8 * 16], hB[16 * 32], *dA, *dB;
  float hD[8 * 32], *dD;
  int va[8 * 16], vb[16 * 32];
  srand(11);
  for (int i = 0; i < 8 * 16; i++) { va[i] = rand() % 9 - 4; hA[i] = half_of(va[i]); }
  for (int i = 0; i < 16 * 32; i++) { vb[i] = rand() % 9 - 4; hB[i] = half_of(vb[i]); }
  cudaMalloc(&dA, sizeof hA); cudaMalloc(&dB, sizeof hB); cudaMalloc(&dD, sizeof hD);
  cudaMemcpy(dA, hA, sizeof hA, cudaMemcpyHostToDevice);
  cudaMemcpy(dB, hB, sizeof hB, cudaMemcpyHostToDevice);
  wmma_api<<<1, 32>>>(dA, dB, dD);
  cudaMemcpy(hD, dD, sizeof hD, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 8; i++)
    for (int j = 0; j < 32; j++) {
      float want = 0.0f;
      for (int k = 0; k < 16; k++) want += (float)va[i * 16 + k] * (float)vb[j * 16 + k];  // B col-major: (k, j) at j*16+k
      if (hD[i * 32 + j] != want) bad++;
    }
  printf("wmma api: %s, %d mismatches\n", bad ? "error" : "no error", bad);
  return bad != 0;
}
