// wmma m8n32k16 (f16 A and B, f32 accumulate) as the PTX instructions that nvcuda::wmma lowers to on sm_70 and later,
// through inline asm: a warp loads A (row-major 8x16), B (col-major 16x32) and C (row-major 8x32) from shared memory,
// runs wmma.mma and stores D. The register counts are the ones nvcc emits (A and B 8 registers each, C and D 8 floats).
// Inputs are small integers, so every product and sum is exact and the host reference is exact.
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>

// Shared-state address of a shared-memory pointer (inline PTX; __cvta_generic_to_shared is refused by name).
#ifdef __CUDA_ARCH__
static __device__ inline unsigned smem_addr(const void *p) {
  unsigned long long q;
  unsigned r;
  asm("cvta.to.shared.u64 %0, %1;" : "=l"(q) : "l"(p));
  asm("cvt.u32.u64 %0, %1;" : "=r"(r) : "l"(q));
  return r;
}
#endif

__global__ void wmma_m8n32k16(const unsigned short *A, const unsigned short *B, const float *C, float *D) {
#ifdef __CUDA_ARCH__
  __shared__ unsigned short sa[8 * 16], sb[16 * 32];
  __shared__ float sc[8 * 32];
  int t = threadIdx.x;
  for (int i = t; i < 8 * 16; i += 32) sa[i] = A[i];
  for (int i = t; i < 16 * 32; i += 32) sb[i] = B[i];
  for (int i = t; i < 8 * 32; i += 32) sc[i] = C[i];
  __syncwarp();
  unsigned a[8], b[8];
  float c[8];
  unsigned sa_addr = smem_addr(sa);
  unsigned sb_addr = smem_addr(sb);
  unsigned sc_addr = smem_addr(sc);
  asm volatile("wmma.load.a.sync.aligned.row.m8n32k16.shared.f16 {%0,%1,%2,%3,%4,%5,%6,%7}, [%8], 16;"
               : "=r"(a[0]), "=r"(a[1]), "=r"(a[2]), "=r"(a[3]), "=r"(a[4]), "=r"(a[5]), "=r"(a[6]), "=r"(a[7])
               : "r"(sa_addr));
  asm volatile("wmma.load.b.sync.aligned.col.m8n32k16.shared.f16 {%0,%1,%2,%3,%4,%5,%6,%7}, [%8], 16;"
               : "=r"(b[0]), "=r"(b[1]), "=r"(b[2]), "=r"(b[3]), "=r"(b[4]), "=r"(b[5]), "=r"(b[6]), "=r"(b[7])
               : "r"(sb_addr));
  asm volatile("wmma.load.c.sync.aligned.row.m8n32k16.shared.f32 {%0,%1,%2,%3,%4,%5,%6,%7}, [%8], 32;"
               : "=f"(c[0]), "=f"(c[1]), "=f"(c[2]), "=f"(c[3]), "=f"(c[4]), "=f"(c[5]), "=f"(c[6]), "=f"(c[7])
               : "r"(sc_addr));
  asm volatile("wmma.mma.sync.aligned.row.col.m8n32k16.f32.f32 "
               "{%0,%1,%2,%3,%4,%5,%6,%7}, {%8,%9,%10,%11,%12,%13,%14,%15}, {%16,%17,%18,%19,%20,%21,%22,%23}, "
               "{%0,%1,%2,%3,%4,%5,%6,%7};"
               : "+f"(c[0]), "+f"(c[1]), "+f"(c[2]), "+f"(c[3]), "+f"(c[4]), "+f"(c[5]), "+f"(c[6]), "+f"(c[7])
               : "r"(a[0]), "r"(a[1]), "r"(a[2]), "r"(a[3]), "r"(a[4]), "r"(a[5]), "r"(a[6]), "r"(a[7]),
                 "r"(b[0]), "r"(b[1]), "r"(b[2]), "r"(b[3]), "r"(b[4]), "r"(b[5]), "r"(b[6]), "r"(b[7]));
  asm volatile("wmma.store.d.sync.aligned.row.m8n32k16.shared.f32 [%0], {%1,%2,%3,%4,%5,%6,%7,%8}, 32;"
               :: "r"(sc_addr), "f"(c[0]), "f"(c[1]), "f"(c[2]), "f"(c[3]), "f"(c[4]), "f"(c[5]), "f"(c[6]), "f"(c[7]));
  __syncwarp();
  for (int i = t; i < 8 * 32; i += 32) D[i] = sc[i];
#endif
}

static unsigned short half_of(int v) {  // small integers as f16 bit patterns (exact for |v| <= 2048)
  unsigned short h = 0;
  if (v == 0) return 0;
  int sign = v < 0; unsigned m = sign ? -v : v; int e = 0;
  while ((m >> e) > 1) e++;
  unsigned frac = ((m << 10) >> e) & 0x3ff;
  return (unsigned short)((sign << 15) | ((e + 15) << 10) | frac);
}

int main() {
  unsigned short hA[8 * 16], hB[16 * 32], *dA, *dB;
  float hC[8 * 32], hD[8 * 32], *dC, *dD;
  int va[8 * 16], vb[16 * 32];
  srand(7);
  for (int i = 0; i < 8 * 16; i++) { va[i] = rand() % 9 - 4; hA[i] = half_of(va[i]); }
  for (int i = 0; i < 16 * 32; i++) { vb[i] = rand() % 9 - 4; hB[i] = half_of(vb[i]); }
  for (int i = 0; i < 8 * 32; i++) hC[i] = (float)(rand() % 17 - 8);
  cudaMalloc(&dA, sizeof hA); cudaMalloc(&dB, sizeof hB); cudaMalloc(&dC, sizeof hC); cudaMalloc(&dD, sizeof hD);
  cudaMemcpy(dA, hA, sizeof hA, cudaMemcpyHostToDevice);
  cudaMemcpy(dB, hB, sizeof hB, cudaMemcpyHostToDevice);
  cudaMemcpy(dC, hC, sizeof hC, cudaMemcpyHostToDevice);
  wmma_m8n32k16<<<1, 32>>>(dA, dB, dC, dD);
  cudaMemcpy(hD, dD, sizeof hD, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < 8; i++)
    for (int j = 0; j < 32; j++) {
      float want = hC[i * 32 + j];
      // B is col-major 16x32: element (k, j) is at B[j * 16 + k]
      for (int k = 0; k < 16; k++) want += (float)va[i * 16 + k] * (float)vb[j * 16 + k];
      if (hD[i * 32 + j] != want) bad++;
    }
  printf("wmma m8n32k16: %s, %d mismatches\n", bad ? "error" : "no error", bad);
  return bad != 0;
}
