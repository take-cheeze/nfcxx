// The integer intrinsics of llama.cpp's ggml-cuda, on one warp (32 lanes), against host references that follow
// CUDA's definitions: __umulhi, __popc, __popcll, __byte_perm (its selector with bit 3 of the nibbles and the bits
// above 16 set, which CUDA ignores, as llama.cpp's q1_0 and FP4 lookups pass it), __vsub4, __vcmpne4 (per-byte wrap
// subtraction and not-equal mask), __shfl_xor_sync and __shfl_down_sync (full warp, width 32).
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void k(unsigned *o, const unsigned *a, const unsigned *b) {
  unsigned i = threadIdx.x;
  unsigned x = a[i], y = b[i];
  o[i * 8 + 0] = __umulhi(x, y);
  o[i * 8 + 1] = (unsigned)__popc(x);
  o[i * 8 + 2] = (unsigned)__popcll(((unsigned long long)x << 32) | y);
  o[i * 8 + 3] = __byte_perm(x, y, 0x73625140u ^ x);
  o[i * 8 + 4] = __vsub4(x, y);
  o[i * 8 + 5] = __vcmpne4(x, y);
  o[i * 8 + 6] = (unsigned)__shfl_xor_sync(0xffffffffu, (int)i, 1);
  o[i * 8 + 7] = (unsigned)__shfl_down_sync(0xffffffffu, (int)i, 2);
}

static unsigned byte_perm(unsigned x, unsigned y, unsigned s) {
  unsigned r = 0;
  for (int i = 0; i < 4; i++) {
    unsigned sel = (s >> (4 * i)) & 7u;
    unsigned src = sel < 4 ? x : y;
    unsigned byte = (src >> (8 * (sel & 3))) & 0xffu;
    r |= byte << (8 * i);
  }
  return r;
}

static unsigned vsub4(unsigned a, unsigned b) {
  unsigned r = 0;
  for (int i = 0; i < 4; i++) r |= (((a >> (8 * i)) - (b >> (8 * i))) & 0xffu) << (8 * i);
  return r;
}

static unsigned vcmpne4(unsigned a, unsigned b) {
  unsigned r = 0;
  for (int i = 0; i < 4; i++)
    if (((a >> (8 * i)) & 0xffu) != ((b >> (8 * i)) & 0xffu)) r |= 0xffu << (8 * i);
  return r;
}

int main() {
  const int n = 32;
  unsigned ha[n], hb[n], ho[n * 8];
  unsigned seed = 2463534242u;
  for (int i = 0; i < n; i++) {
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    ha[i] = seed;
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    hb[i] = (i % 4 == 0) ? ha[i] : seed;  // some lanes equal, so __vcmpne4 has zero bytes
  }
  unsigned *da, *db, *dout;
  cudaMalloc((void **)&da, sizeof ha);
  cudaMalloc((void **)&db, sizeof hb);
  cudaMalloc((void **)&dout, sizeof ho);
  cudaMemcpy(da, ha, sizeof ha, cudaMemcpyHostToDevice);
  cudaMemcpy(db, hb, sizeof hb, cudaMemcpyHostToDevice);
  k<<<1, 32>>>(dout, da, db);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(ho, dout, sizeof ho, cudaMemcpyDeviceToHost);

  int bad = 0;
  for (int i = 0; i < n; i++) {
    unsigned x = ha[i], y = hb[i];
    unsigned ref[8];
    ref[0] = (unsigned)(((unsigned long long)x * y) >> 32);
    ref[1] = (unsigned)__builtin_popcount(x);
    ref[2] = (unsigned)__builtin_popcountll(((unsigned long long)x << 32) | y);
    ref[3] = byte_perm(x, y, 0x73625140u ^ x);
    ref[4] = vsub4(x, y);
    ref[5] = vcmpne4(x, y);
    ref[6] = (unsigned)(i ^ 1u);
    ref[7] = (unsigned)(i + 2 < 32 ? i + 2 : i);
    for (int j = 0; j < 8; j++) bad += ho[i * 8 + j] != ref[j];
  }
  printf("intrinsics: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  cudaFree(da); cudaFree(db); cudaFree(dout);
  return bad != 0;
}
