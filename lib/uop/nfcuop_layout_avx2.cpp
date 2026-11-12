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

// 8x8 transpose of f32 in ymm registers: 8 unpacks, 8 shuffles and 8 permutes, 24 instructions per 64 elements.
// Loads 8 rows of length 8 from src (row stride lda) and stores the transpose at dst (row stride ldd).
const char* kTranspose8 =
    "static inline void nfc_tr8(const float* src, int64_t lda, float* dst, int64_t ldd) {\n"
    "  __m256 r0 = _mm256_loadu_ps(src + 0 * lda), r1 = _mm256_loadu_ps(src + 1 * lda);\n"
    "  __m256 r2 = _mm256_loadu_ps(src + 2 * lda), r3 = _mm256_loadu_ps(src + 3 * lda);\n"
    "  __m256 r4 = _mm256_loadu_ps(src + 4 * lda), r5 = _mm256_loadu_ps(src + 5 * lda);\n"
    "  __m256 r6 = _mm256_loadu_ps(src + 6 * lda), r7 = _mm256_loadu_ps(src + 7 * lda);\n"
    "  __m256 t0 = _mm256_unpacklo_ps(r0, r1), t1 = _mm256_unpackhi_ps(r0, r1);\n"
    "  __m256 t2 = _mm256_unpacklo_ps(r2, r3), t3 = _mm256_unpackhi_ps(r2, r3);\n"
    "  __m256 t4 = _mm256_unpacklo_ps(r4, r5), t5 = _mm256_unpackhi_ps(r4, r5);\n"
    "  __m256 t6 = _mm256_unpacklo_ps(r6, r7), t7 = _mm256_unpackhi_ps(r6, r7);\n"
    "  __m256 s0 = _mm256_shuffle_ps(t0, t2, 0x44), s1 = _mm256_shuffle_ps(t0, t2, 0xEE);\n"
    "  __m256 s2 = _mm256_shuffle_ps(t1, t3, 0x44), s3 = _mm256_shuffle_ps(t1, t3, 0xEE);\n"
    "  __m256 s4 = _mm256_shuffle_ps(t4, t6, 0x44), s5 = _mm256_shuffle_ps(t4, t6, 0xEE);\n"
    "  __m256 s6 = _mm256_shuffle_ps(t5, t7, 0x44), s7 = _mm256_shuffle_ps(t5, t7, 0xEE);\n"
    "  _mm256_storeu_ps(dst + 0 * ldd, _mm256_permute2f128_ps(s0, s4, 0x20));\n"
    "  _mm256_storeu_ps(dst + 1 * ldd, _mm256_permute2f128_ps(s1, s5, 0x20));\n"
    "  _mm256_storeu_ps(dst + 2 * ldd, _mm256_permute2f128_ps(s2, s6, 0x20));\n"
    "  _mm256_storeu_ps(dst + 3 * ldd, _mm256_permute2f128_ps(s3, s7, 0x20));\n"
    "  _mm256_storeu_ps(dst + 4 * ldd, _mm256_permute2f128_ps(s0, s4, 0x31));\n"
    "  _mm256_storeu_ps(dst + 5 * ldd, _mm256_permute2f128_ps(s1, s5, 0x31));\n"
    "  _mm256_storeu_ps(dst + 6 * ldd, _mm256_permute2f128_ps(s2, s6, 0x31));\n"
    "  _mm256_storeu_ps(dst + 7 * ldd, _mm256_permute2f128_ps(s3, s7, 0x31));\n"
    "}\n";

}  // namespace

std::string emit_gemm_rowsum_c(GemmVariant v, int64_t M, int64_t N, int64_t K, bool simd_transpose, Storage storage) {
  if (M < 1 || N < 1 || K < 1) throw std::invalid_argument("emit_gemm_rowsum_c: sizes must be positive");
  std::ostringstream o;
  o << kPrologue << kHsum;
  if (v == GemmVariant::VecM && simd_transpose) o << kTranspose8;
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
    const bool blk = storage == Storage::Blocked8;
    // Index of A^T (At) for column k and row m. Strided: k*M + m. Blocked8: the 8-row block starts at m - m%8,
    // with its k-th group of 8 contiguous: (m - m%8)*K + k*8 + m%8.
    auto at_index = [&](const std::string& k, const std::string& m) {
      if (!blk) return "At[" + k + " * " + std::to_string(M) + " + " + m + "]";
      return "At[(" + m + " - " + m + " % 8) * " + std::to_string(K) + " + " + k + " * 8 + " + m + " % 8]";
    };
    // The repair: A transposed into At, so that for fixed k the eight lanes are eight consecutive rows of A.
    if (simd_transpose) {
      // 8x8 blocks while k + 8 <= K, then the scalar columns K - K % 8 .. K - 1.
      if (!blk) {
        o << "  for (int64_t m = 0; m < " << M << "; m += 8)\n"
          << "    for (int64_t k = 0; k + 8 <= " << K << "; k += 8)\n"
          << "      nfc_tr8(&A[m * " << K << " + k], " << K << ", &At[k * " << M << " + m], " << M << ");\n";
      } else {
        // The 8x8 block of rows m..m+7, columns k..k+7 goes to the block at m*K: its row k+c is 8 contiguous floats.
        o << "  for (int64_t m = 0; m < " << M << "; m += 8)\n"
          << "    for (int64_t k = 0; k + 8 <= " << K << "; k += 8)\n"
          << "      nfc_tr8(&A[m * " << K << " + k], " << K << ", &At[m * " << K << " + k * 8], 8);\n";
      }
      o << "  for (int64_t m = 0; m < " << M << "; ++m)\n"
        << "    for (int64_t k = " << (K - K % 8) << "; k < " << K << "; ++k)\n"
        << "      " << at_index("k", "m") << " = A[m * " << K << " + k];\n";
    } else {
      o << "  for (int64_t m = 0; m < " << M << "; ++m)\n"
        << "    for (int64_t k = 0; k < " << K << "; ++k)\n"
        << "      " << at_index("k", "m") << " = A[m * " << K << " + k];\n";
    }
    // Lanes on M. Strided: C is written column-major (C[n*M + m]). Blocked8: the 8 rows of a block are contiguous
    // for each n, the block at m*N (m a multiple of 8). The row sum adds the N columns vertically in both.
    const std::string c_store = blk ? "&C[m * " + std::to_string(N) + " + n * 8]" : "&C[n * " + std::to_string(M) + " + m]";
    const std::string at_load = blk ? "&At[m * " + std::to_string(K) + " + k * 8]" : "&At[k * " + std::to_string(M) + " + m]";
    o << "  for (int64_t m = 0; m < " << M << "; m += 8) {\n"
      << "    __m256 rs = _mm256_setzero_ps();\n"
      << "    for (int64_t n = 0; n < " << N << "; ++n) {\n"
      << "      __m256 acc = _mm256_setzero_ps();\n"
      << "      for (int64_t k = 0; k < " << K << "; ++k)\n"
      << "        acc = _mm256_fmadd_ps(_mm256_loadu_ps(" << at_load << "),\n"
      << "                              _mm256_broadcast_ss(&B[k * " << N << " + n]), acc);\n"
      << "      _mm256_storeu_ps(" << c_store << ", acc);\n"
      << "      rs = _mm256_add_ps(rs, acc);\n"
      << "    }\n"
      << "    _mm256_storeu_ps(&R[m], rs);\n"
      << "  }\n";
  }
  o << "}\n";
  return o.str();
}

std::string emit_gemm_rowsum_packed_c(int64_t M, int64_t N, int64_t K) {
  if (M < 1 || N < 1 || K < 1) throw std::invalid_argument("emit_gemm_rowsum_packed_c: sizes must be positive");
  if (M % 4 != 0) throw std::invalid_argument("emit_gemm_rowsum_packed_c: needs M % 4 == 0");
  if (N % 16 != 0) throw std::invalid_argument("emit_gemm_rowsum_packed_c: needs N % 16 == 0");
  std::ostringstream o;
  o << kPrologue << kHsum;
  o << "void nfc_gemm_rowsum(const float* A, const float* B, float* C, float* R, float* Bp) {\n"
    << "  /* pack B: panel p (16 columns) holds K rows of 16 contiguous floats at Bp[p*K*16 + k*16 + j] */\n"
    << "  for (int64_t p = 0; p < " << (N / 16) << "; ++p)\n"
    << "    for (int64_t k = 0; k < " << K << "; ++k)\n"
    << "      for (int64_t j = 0; j < 16; ++j) Bp[p * " << K * 16 << " + k * 16 + j] = B[k * " << N << " + p * 16 + j];\n"
    << "  for (int64_t i = 0; i < " << M << "; i += 4) {\n"
    << "    __m256 rs0 = _mm256_setzero_ps(), rs1 = rs0, rs2 = rs0, rs3 = rs0;\n"
    << "    for (int64_t n = 0; n < " << N << "; n += 16) {\n"
    << "      const float* bn = Bp + (n / 16) * " << K * 16 << ";\n"
    << "      __m256 c00 = _mm256_setzero_ps(), c01 = c00, c10 = c00, c11 = c00;\n"
    << "      __m256 c20 = c00, c21 = c00, c30 = c00, c31 = c00;\n"
    << "      for (int64_t k = 0; k < " << K << "; ++k) {\n"
    << "        __m256 b0 = _mm256_loadu_ps(bn + k * 16), b1 = _mm256_loadu_ps(bn + k * 16 + 8), x;\n"
    << "        x = _mm256_broadcast_ss(&A[(i + 0) * " << K << " + k]); c00 = _mm256_fmadd_ps(x, b0, c00); c01 = _mm256_fmadd_ps(x, b1, c01);\n"
    << "        x = _mm256_broadcast_ss(&A[(i + 1) * " << K << " + k]); c10 = _mm256_fmadd_ps(x, b0, c10); c11 = _mm256_fmadd_ps(x, b1, c11);\n"
    << "        x = _mm256_broadcast_ss(&A[(i + 2) * " << K << " + k]); c20 = _mm256_fmadd_ps(x, b0, c20); c21 = _mm256_fmadd_ps(x, b1, c21);\n"
    << "        x = _mm256_broadcast_ss(&A[(i + 3) * " << K << " + k]); c30 = _mm256_fmadd_ps(x, b0, c30); c31 = _mm256_fmadd_ps(x, b1, c31);\n"
    << "      }\n"
    << "      _mm256_storeu_ps(&C[(i + 0) * " << N << " + n], c00); _mm256_storeu_ps(&C[(i + 0) * " << N << " + n + 8], c01);\n"
    << "      _mm256_storeu_ps(&C[(i + 1) * " << N << " + n], c10); _mm256_storeu_ps(&C[(i + 1) * " << N << " + n + 8], c11);\n"
    << "      _mm256_storeu_ps(&C[(i + 2) * " << N << " + n], c20); _mm256_storeu_ps(&C[(i + 2) * " << N << " + n + 8], c21);\n"
    << "      _mm256_storeu_ps(&C[(i + 3) * " << N << " + n], c30); _mm256_storeu_ps(&C[(i + 3) * " << N << " + n + 8], c31);\n"
    << "      rs0 = _mm256_add_ps(rs0, _mm256_add_ps(c00, c01)); rs1 = _mm256_add_ps(rs1, _mm256_add_ps(c10, c11));\n"
    << "      rs2 = _mm256_add_ps(rs2, _mm256_add_ps(c20, c21)); rs3 = _mm256_add_ps(rs3, _mm256_add_ps(c30, c31));\n"
    << "    }\n"
    << "    R[i + 0] = nfc_hsum(rs0); R[i + 1] = nfc_hsum(rs1); R[i + 2] = nfc_hsum(rs2); R[i + 3] = nfc_hsum(rs3);\n"
    << "  }\n"
    << "}\n";
  return o.str();
}

}  // namespace nfcuop::layout
