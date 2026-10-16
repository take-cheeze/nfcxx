// Value check of the ported lowering: the cubin of value.ptx (gen.sh, the lowering's text per operator) against the
// same operators written in CUDA and compiled by nvcc. Both run on the same inputs; results are compared bit for bit
// at the result's width. Inputs avoid the trap conditions (zero divisors, -1 divisors, out-of-range shift counts,
// out-of-range float to integer), since a trapping case is refused by the lowering, not compared.
#include <cuda.h>
#include <cuda_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { fprintf(stderr, "%s: %s\n", #x, cudaGetErrorString(e_)); exit(2); } } while (0)

// The reference: each row's operator in CUDA, on the 8-byte slots the kernels read and write.
__device__ unsigned long long ref(int id, unsigned long long A, unsigned long long B) {
  int32_t ai = (int32_t)A, bi = (int32_t)B;
  uint32_t au = (uint32_t)A, bu = (uint32_t)B;
  int64_t al = (int64_t)A;
  uint64_t aul = A, bul = B;
  float af = __uint_as_float((uint32_t)A), bf = __uint_as_float((uint32_t)B);
  double ad = __longlong_as_double((long long)A), bd = __longlong_as_double((long long)B);
  switch (id) {
    case 0: return (uint32_t)(au + bu);
    case 1: return (uint32_t)(au * bu);
    case 2: return (uint32_t)(ai / bi);
    case 3: return (uint32_t)(ai % bi);
    case 4: return aul / bul;
    case 5: return (uint32_t)(au % bu);
    case 6: return (uint32_t)(au << bi);
    case 7: return (uint32_t)(au >> (uint32_t)bul);
    case 8: return (uint32_t)(ai >> bi);
    case 9: return (uint32_t)(au & bu);
    case 10: return (uint32_t)(au | bu);
    case 11: return aul ^ bul;
    case 12: return (uint32_t)~au;
    case 13: return (uint32_t)(0u - au);
    case 14: return aul - bul;
    case 15: return aul * bul;
    case 16: return (uint64_t)(int64_t)ai;
    case 17: return (uint32_t)aul;
    case 18: return __float_as_uint(af + bf);
    case 19: return (uint64_t)__double_as_longlong(ad / bd);
    case 20: return __float_as_uint(-af);
    case 21: return __float_as_uint((float)ad);
    case 22: return (uint32_t)(int32_t)af;
    case 23: return (uint64_t)(int64_t)ad;
    case 24: return (uint64_t)__double_as_longlong((double)ai);
    case 25: return __float_as_uint((float)au);
    case 26: return ai < bi;
    case 27: return au < bu;
    case 28: return af != bf;
    case 29: return aul == bul;
    case 30: return ad >= bd;
    case 31: return __float_as_uint((float)al);
    case 32: return (uint64_t)__double_as_longlong(ad * bd);
    case 33: return ~aul;
    case 34: return aul << (uint32_t)bi;
  }
  return 0;
}

__global__ void refk(int id, const unsigned long long *A, const unsigned long long *B, unsigned long long *O, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) O[i] = ref(id, A[i], B[i]);
}

// Per row: the kinds of the operands (i: raw integer bits, f: float, d: double, -: none), the result's width in bytes,
// the row's name, and the range of its float or count operand.
struct Row { const char *name; char a, b; int dsize; };
static const Row rows[] = {
  {"wadd int", 'i', 'i', 4}, {"wmul unsigned_int", 'i', 'i', 4}, {"cdiv int", 'i', 'i', 4}, {"crem int", 'i', 'i', 4},
  {"cdiv unsigned_long", 'i', 'i', 8}, {"crem unsigned_int", 'i', 'i', 4}, {"cshl int", 'i', 'i', 4},
  {"cshr unsigned_int", 'i', 'i', 4}, {"cshr int", 'i', 'i', 4}, {"and int", 'i', 'i', 4}, {"or int", 'i', 'i', 4},
  {"xor unsigned_long", 'i', 'i', 8}, {"not int", 'i', '-', 4}, {"wneg int", 'i', '-', 4}, {"wsub long", 'i', 'i', 8},
  {"wmul long", 'i', 'i', 8}, {"iconv long", 'i', '-', 8}, {"iconv int", 'i', '-', 4}, {"fadd float", 'f', 'f', 4},
  {"fdiv double", 'd', 'd', 8}, {"fneg float", 'f', '-', 4}, {"fconv float", 'd', '-', 4}, {"cf2i int", 'f', '-', 4},
  {"cf2i long", 'd', '-', 8}, {"i2f double", 'i', '-', 8}, {"u2f float", 'i', '-', 4}, {"lt int", 'i', 'i', 4},
  {"lt.u unsigned_int", 'i', 'i', 4}, {"ne float", 'f', 'f', 4}, {"eq unsigned_long", 'i', 'i', 4},
  {"ge double", 'd', 'd', 4}, {"i2f float", 'i', '-', 4}, {"fmul double", 'd', 'd', 8}, {"not long", 'i', '-', 8},
  {"cshl long", 'i', 'i', 8},
};
static const int NROWS = sizeof(rows) / sizeof(rows[0]);

static void fill(std::mt19937_64 &g, std::vector<unsigned long long> &v, char kind, int id, bool is_b) {
  std::uniform_real_distribution<double> wide(-1000.0, 1000.0), huge(-2e9, 2e9), big(-1e18, 1e18);
  for (size_t i = 0; i < v.size(); i++) {
    unsigned long long x = g();
    if (kind == 'f') {
      float f = (float)wide(g);
      if (id == 22 && !is_b) f = (float)huge(g);
      uint32_t u;
      memcpy(&u, &f, 4);
      x = u;
    } else if (kind == 'd') {
      double d = (id == 23 && !is_b) ? big(g) : wide(g);
      memcpy(&x, &d, 8);
    }
    // Operands that must not trap: a nonzero divisor that is not -1, and a count in range.
    if (is_b && (id == 2 || id == 3) && ((int32_t)x == 0 || (int32_t)x == -1)) x = 7;
    if (is_b && (id == 4 || id == 5) && x == 0) x = 9;
    if (is_b && (id == 6 || id == 8)) x = g() % 32;
    if (is_b && (id == 7)) x = g() % 32;
    if (is_b && id == 34) x = g() % 64;
    v[i] = x;
  }
}

int main(int argc, char **argv) {
  const char *cubin = argc > 1 ? argv[1] : "value.cubin";
  const int N = 4096;
  CK(cudaFree(0));
  CUmodule mod;
  if (cuModuleLoad(&mod, cubin) != CUDA_SUCCESS) { fprintf(stderr, "cuModuleLoad %s\n", cubin); return 2; }
  unsigned long long *dA, *dB, *dO, *dR;
  CK(cudaMalloc(&dA, N * 8)); CK(cudaMalloc(&dB, N * 8)); CK(cudaMalloc(&dO, N * 8)); CK(cudaMalloc(&dR, N * 8));
  std::mt19937_64 g(20261016);
  int total_bad = 0;
  for (int id = 0; id < NROWS; id++) {
    std::vector<unsigned long long> A(N), B(N, 0), O(N, 0), R(N, 0);
    fill(g, A, rows[id].a, id, false);
    if (rows[id].b != '-') {
      fill(g, B, rows[id].b, id, true);
      if (id == 28 || id == 29)
        for (int i = 0; i < N; i += 2) B[i] = A[i];  // the equal pairs
    }
    CK(cudaMemcpy(dA, A.data(), N * 8, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB, B.data(), N * 8, cudaMemcpyHostToDevice));
    CK(cudaMemset(dO, 0, N * 8));
    CK(cudaMemset(dR, 0, N * 8));
    char kname[16];
    snprintf(kname, sizeof kname, "k%d", id);
    CUfunction f;
    if (cuModuleGetFunction(&f, mod, kname) != CUDA_SUCCESS) { fprintf(stderr, "no %s\n", kname); return 2; }
    // The kernel's pn parameter is a 32-bit element count.
    unsigned int n32 = N;
    void *args2[] = {&dA, &dB, &dO, &n32};
    if (cuLaunchKernel(f, N / 256, 1, 1, 256, 1, 1, 0, 0, args2, 0) != CUDA_SUCCESS) { fprintf(stderr, "launch %s\n", kname); return 2; }
    CK(cudaDeviceSynchronize());
    refk<<<N / 256, 256>>>(id, dA, dB, dR, N);
    CK(cudaDeviceSynchronize());
    CK(cudaMemcpy(O.data(), dO, N * 8, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(R.data(), dR, N * 8, cudaMemcpyDeviceToHost));
    unsigned long long mask = rows[id].dsize == 8 ? ~0ull : 0xffffffffull;
    int bad = 0, first = -1;
    for (int i = 0; i < N; i++) {
      if ((O[i] & mask) != (R[i] & mask)) { if (first < 0) first = i; bad++; }
    }
    total_bad += bad;
    printf("%-22s %4d elements  %4d mismatches", rows[id].name, N, bad);
    if (bad) printf("  first i=%d A=%016llx B=%016llx lowered=%016llx nvcc=%016llx", first, A[first], B[first], O[first] & mask, R[first] & mask);
    printf("\n");
  }
  printf("value check: %d rows, %d mismatches\n", NROWS, total_bad);
  return total_bad != 0;
}
