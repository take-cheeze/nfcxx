// Value check of the device-intrinsic, warp, atomic and ptx-asm lowering: the cubin of call-value.ptx (call-gen.sh, the
// lowering's text per row) against the same operations written in CUDA and compiled by nvcc. Both run on the same inputs
// (A and B per element, the scratch slot of each element, a copy of A); results and the scratch slots are compared bit
// for bit. The row table matches call-cases.tsv: the row's id is its kernel name's number.
#include <cuda.h>
#include <cuda_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); exit(2); } } while (0)

// The reference: each row's operation in CUDA. O receives the result (mode r rows), S the scratch slot of the element.
__global__ void refk(int id, const unsigned long long *A, const unsigned long long *B, unsigned long long *O,
                     unsigned long long *S, int n) {
  __shared__ int red[8];
  const unsigned FULL = 0xffffffffu;
  int lane = threadIdx.x & 31, w = threadIdx.x >> 5;
  if (lane == 0) red[w] = 0;
  __syncwarp();
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int32_t ai = (int32_t)A[i], bi = (int32_t)B[i];
  float af = __uint_as_float((uint32_t)A[i]), bf = __uint_as_float((uint32_t)B[i]);
  uint32_t r = 0;
  int32_t *p = (int32_t *)&S[i];
  float *pf = (float *)&S[i];
  switch (id) {
    case 0: r = (uint32_t)__shfl_sync(FULL, ai, bi); break;
    case 1: r = __float_as_uint(__shfl_sync(FULL, af, bi)); break;
    case 2: r = (uint32_t)__shfl_xor_sync(FULL, ai, bi); break;
    case 3: r = __float_as_uint(__shfl_xor_sync(FULL, af, bi)); break;
    case 4: r = (uint32_t)__shfl_down_sync(FULL, ai, bi); break;
    case 5: r = __float_as_uint(__shfl_down_sync(FULL, af, bi)); break;
    case 6: r = (uint32_t)__shfl_up_sync(FULL, ai, bi); break;
    case 7: r = __float_as_uint(__shfl_up_sync(FULL, af, bi)); break;
    case 8: r = (uint32_t)__ballot_sync(FULL, ai != 0); break;
    case 9: r = (uint32_t)__any_sync(FULL, ai != 0); break;
    case 10: r = (uint32_t)__all_sync(FULL, ai != 0); break;
    case 11:  // the warp sum, by shared-memory atomics (an independent reference for the butterfly)
      atomicAdd(&red[w], ai);
      __syncwarp();
      r = (uint32_t)red[w];
      break;
    case 12: r = (uint32_t)atomicAdd(p, bi); break;
    case 13: r = (uint32_t)atomicMax(p, bi); break;
    case 14: r = (uint32_t)atomicCAS(p, ai, bi); break;
    case 15: r = __float_as_uint(atomicAdd(pf, bf)); break;
    case 16: *p = (int32_t)((uint32_t)ai + (uint32_t)bi); break;
    case 17: *p = (int32_t)((uint32_t)ai + (uint32_t)bi); break;
    case 18: *pf = af + bf; break;
  }
  O[i] = r;
}

// Per row: the kind of the A operand (i: raw integer bits, f: float), of the B operand, and the row's name.
struct Row { const char *name; char a, b; };
static const Row rows[] = {
  {"shfl_sync i", 'i', 'l'}, {"shfl_sync f", 'f', 'l'}, {"shfl_xor i", 'i', 'l'}, {"shfl_xor f", 'f', 'l'},
  {"shfl_down i", 'i', 'l'}, {"shfl_down f", 'f', 'l'}, {"shfl_up i", 'i', 'l'}, {"shfl_up f", 'f', 'l'},
  {"ballot", 'i', 'i'}, {"any", 'i', 'i'}, {"all", 'i', 'i'}, {"reduce_add", 'i', 'i'},
  {"atomic_add i", 'i', 'i'}, {"atomic_max i", 'i', 'i'}, {"atomic_cas i", 'i', 'i'}, {"atomic_add f", 'f', 'f'},
  {"asm add.s32 out", 'i', 'i'}, {"asm add.s32 inout", 'i', 'i'}, {"asm add.f32", 'f', 'f'},
};
static const int NROWS = sizeof(rows) / sizeof(rows[0]);

// Operands: an element of kind 'f' is a float in [-1000, 1000]; 'l' is a lane (0..31); 'i' is any 32-bit pattern.
static void fill(std::mt19937_64 &g, std::vector<unsigned long long> &v, char kind) {
  std::uniform_real_distribution<float> wide(-1000.0f, 1000.0f);
  for (size_t i = 0; i < v.size(); i++) {
    unsigned long long x = g() & 0xffffffffull;
    if (kind == 'f') {
      float f = wide(g);
      uint32_t u;
      memcpy(&u, &f, 4);
      x = u;
    } else if (kind == 'l') {
      x = g() % 32;
    }
    v[i] = x;
  }
}

int main(int argc, char **argv) {
  const char *cubin = argc > 1 ? argv[1] : "call-value.cubin";
  const int N = 4096;
  CK(cudaFree(0));
  CUmodule mod;
  if (cuModuleLoad(&mod, cubin) != CUDA_SUCCESS) { fprintf(stderr, "cuModuleLoad %s\n", cubin); return 2; }
  unsigned long long *dA, *dB, *dOl, *dOr, *dSl, *dSr;
  CK(cudaMalloc(&dA, N * 8)); CK(cudaMalloc(&dB, N * 8));
  CK(cudaMalloc(&dOl, N * 8)); CK(cudaMalloc(&dOr, N * 8));
  CK(cudaMalloc(&dSl, N * 8)); CK(cudaMalloc(&dSr, N * 8));
  std::mt19937_64 g(20261016);
  int total_bad = 0;
  for (int id = 0; id < NROWS; id++) {
    std::vector<unsigned long long> A(N), B(N), Ol(N, 0), Or(N, 0), Sl(N), Sr(N);
    fill(g, A, rows[id].a);
    fill(g, B, rows[id].b);
    // the scratch slots start at A (the atomics and the inout statement read them)
    Sl = A;
    Sr = A;
    CK(cudaMemcpy(dA, A.data(), N * 8, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB, B.data(), N * 8, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dSl, Sl.data(), N * 8, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dSr, Sr.data(), N * 8, cudaMemcpyHostToDevice));
    CK(cudaMemset(dOl, 0, N * 8));
    CK(cudaMemset(dOr, 0, N * 8));
    char kname[16];
    snprintf(kname, sizeof kname, "k%d", id);
    CUfunction f;
    if (cuModuleGetFunction(&f, mod, kname) != CUDA_SUCCESS) { fprintf(stderr, "no %s\n", kname); return 2; }
    unsigned int n32 = N;
    void *args[] = {&dA, &dB, &dOl, &dSl, &n32};
    if (cuLaunchKernel(f, N / 256, 1, 1, 256, 1, 1, 0, 0, args, 0) != CUDA_SUCCESS) { fprintf(stderr, "launch %s\n", kname); return 2; }
    CK(cudaDeviceSynchronize());
    refk<<<N / 256, 256>>>(id, dA, dB, dOr, dSr, N);
    CK(cudaDeviceSynchronize());
    CK(cudaMemcpy(Ol.data(), dOl, N * 8, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(Or.data(), dOr, N * 8, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(Sl.data(), dSl, N * 8, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(Sr.data(), dSr, N * 8, cudaMemcpyDeviceToHost));
    // mode r rows compare the result; every row compares its scratch slot. Both at 4 bytes (the low word of the slot).
    bool is_m = id >= 16;
    int bad = 0, first = -1;
    for (int i = 0; i < N; i++) {
      bool res_bad = !is_m && (uint32_t)Ol[i] != (uint32_t)Or[i];
      bool slot_bad = (uint32_t)Sl[i] != (uint32_t)Sr[i];
      if (res_bad || slot_bad) { if (first < 0) first = i; bad++; }
    }
    total_bad += bad;
    printf("%-18s %4d elements  %4d mismatches", rows[id].name, N, bad);
    if (bad)
      printf("  first i=%d A=%08llx B=%08llx lowered=%08llx nvcc=%08llx slot=%08llx/%08llx", first, A[first] & 0xffffffffull,
             B[first] & 0xffffffffull, Ol[first] & 0xffffffffull, Or[first] & 0xffffffffull, Sl[first] & 0xffffffffull,
             Sr[first] & 0xffffffffull);
    printf("\n");
  }
  printf("call value check: %d rows, %d mismatches\n", NROWS, total_bad);
  return total_bad != 0;
}
