// nfcuop layout, AVX2 emitter: see nfcuop_layout_avx2.hpp.
#include "nfcuop_layout_avx2.hpp"

#include <sstream>
#include <stdexcept>

namespace nfcuop::layout {

namespace {

const char* kPrologue =
    "#include <immintrin.h>\n"
    "#include <stdint.h>\n";

// Horizontal sum of the eight lanes of a ymm register, in the order the model's hsum costs (3 shuffles, 3 adds).
const char* kHsum =
    "static inline float nfc_hsum(__m256 v) {\n"
    "  __m128 s = _mm_add_ps(_mm256_castps256_ps128(v), _mm256_extractf128_ps(v, 1));\n"
    "  s = _mm_add_ps(s, _mm_movehl_ps(s, s));\n"
    "  s = _mm_add_ss(s, _mm_shuffle_ps(s, s, 1));\n"
    "  return _mm_cvtss_f32(s);\n"
    "}\n";

}  // namespace

std::string emit_gemm_rowsum_c(GemmVariant v, int64_t M, int64_t N, int64_t K) {
  if (M < 1 || N < 1 || K < 1) throw std::invalid_argument("emit_gemm_rowsum_c: sizes must be positive");
  std::ostringstream o;
  o << kPrologue << kHsum;
  o << "void nfc_gemm_rowsum(const float* A, const float* B, float* C, float* R, float* At) {\n";
  if (v == GemmVariant::VecN) {
    if (N % 8 != 0) throw std::invalid_argument("emit_gemm_rowsum_c: VecN needs N % 8 == 0");
    // Lanes on N: C and B row-major (the lanes are consecutive columns), A broadcast.
    o << "  for (int64_t i = 0; i < " << M << "; ++i) {\n"
      << "    __m256 rs = _mm256_setzero_ps();\n"
      << "    for (int64_t n = 0; n < " << N << "; n += 8) {\n"
      << "      __m256 acc = _mm256_setzero_ps();\n"
      << "      for (int64_t k = 0; k < " << K << "; ++k)\n"
      << "        acc = _mm256_fmadd_ps(_mm256_broadcast_ss(&A[i * " << K << " + k]),\n"
      << "                              _mm256_loadu_ps(&B[k * " << N << " + n]), acc);\n"
      << "      _mm256_storeu_ps(&C[i * " << N << " + n], acc);\n"
      << "      rs = _mm256_add_ps(rs, acc);\n"
      << "    }\n"
      << "    R[i] = nfc_hsum(rs);\n"
      << "  }\n";
  } else {
    if (M % 8 != 0) throw std::invalid_argument("emit_gemm_rowsum_c: VecM needs M % 8 == 0");
    // The repair: A transposed into At (K x M), so that for fixed k the eight lanes are eight consecutive rows of A.
    o << "  for (int64_t m = 0; m < " << M << "; ++m)\n"
      << "    for (int64_t k = 0; k < " << K << "; ++k)\n"
      << "      At[k * " << M << " + m] = A[m * " << K << " + k];\n"
      // Lanes on M: C is written column-major (C[n*M + m]), the row sum adds the N columns vertically.
      << "  for (int64_t m = 0; m < " << M << "; m += 8) {\n"
      << "    __m256 rs = _mm256_setzero_ps();\n"
      << "    for (int64_t n = 0; n < " << N << "; ++n) {\n"
      << "      __m256 acc = _mm256_setzero_ps();\n"
      << "      for (int64_t k = 0; k < " << K << "; ++k)\n"
      << "        acc = _mm256_fmadd_ps(_mm256_loadu_ps(&At[k * " << M << " + m]),\n"
      << "                              _mm256_broadcast_ss(&B[k * " << N << " + n]), acc);\n"
      << "      _mm256_storeu_ps(&C[n * " << M << " + m], acc);\n"
      << "      rs = _mm256_add_ps(rs, acc);\n"
      << "    }\n"
      << "    _mm256_storeu_ps(&R[m], rs);\n"
      << "  }\n";
  }
  o << "}\n";
  return o.str();
}

}  // namespace nfcuop::layout
