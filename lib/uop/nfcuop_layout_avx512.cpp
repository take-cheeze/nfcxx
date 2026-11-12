// nfcuop layout, AVX-512 emitter: see nfcuop_layout_avx512.hpp.
#include "nfcuop_layout_avx512.hpp"

#include <sstream>
#include <stdexcept>

namespace nfcuop::layout {

std::string emit_gemm_rowsum_packed512_c(int64_t M, int64_t N, int64_t K, int mr) {
  if (M < 1 || N < 1 || K < 1) throw std::invalid_argument("emit_gemm_rowsum_packed512_c: sizes must be positive");
  if (mr != 4 && mr != 6) throw std::invalid_argument("emit_gemm_rowsum_packed512_c: the row tile is 4 or 6");
  if (M % mr != 0) throw std::invalid_argument("emit_gemm_rowsum_packed512_c: needs M % mr == 0");
  if (N % 32 != 0) throw std::invalid_argument("emit_gemm_rowsum_packed512_c: needs N % 32 == 0");
  std::ostringstream o;
  o << "#include <immintrin.h>\n#include <stdint.h>\n";
  o << "void nfc_gemm_rowsum(const float* A, const float* B, float* C, float* R, float* Bp) {\n"
    << "  /* pack B: panel p (32 columns) holds K rows of 32 contiguous floats at Bp[p*K*32 + k*32 + j] */\n"
    << "  for (int64_t p = 0; p < " << (N / 32) << "; ++p)\n"
    << "    for (int64_t k = 0; k < " << K << "; ++k)\n"
    << "      for (int64_t j = 0; j < 32; ++j) Bp[p * " << K * 32 << " + k * 32 + j] = B[k * " << N << " + p * 32 + j];\n"
    << "  for (int64_t i = 0; i < " << M << "; i += " << mr << ") {\n";
  for (int r = 0; r < mr; ++r) o << "    __m512 rs" << r << " = _mm512_setzero_ps();\n";
  o << "    for (int64_t n = 0; n < " << N << "; n += 32) {\n"
    << "      const float* bn = Bp + (n / 32) * " << K * 32 << ";\n";
  for (int r = 0; r < mr; ++r)
    o << "      __m512 c" << r << "0 = _mm512_setzero_ps(), c" << r << "1 = _mm512_setzero_ps();\n";
  o << "      for (int64_t k = 0; k < " << K << "; ++k) {\n"
    << "        __m512 b0 = _mm512_loadu_ps(bn + k * 32), b1 = _mm512_loadu_ps(bn + k * 32 + 16), x;\n";
  for (int r = 0; r < mr; ++r)
    o << "        x = _mm512_set1_ps(A[(i + " << r << ") * " << K << " + k]); c" << r << "0 = _mm512_fmadd_ps(x, b0, c" << r
      << "0); c" << r << "1 = _mm512_fmadd_ps(x, b1, c" << r << "1);\n";
  o << "      }\n";
  for (int r = 0; r < mr; ++r)
    o << "      _mm512_storeu_ps(&C[(i + " << r << ") * " << N << " + n], c" << r << "0); _mm512_storeu_ps(&C[(i + " << r
      << ") * " << N << " + n + 16], c" << r << "1);\n";
  for (int r = 0; r < mr; ++r)
    o << "      rs" << r << " = _mm512_add_ps(rs" << r << ", _mm512_add_ps(c" << r << "0, c" << r << "1));\n";
  o << "    }\n";
  for (int r = 0; r < mr; ++r) o << "    R[i + " << r << "] = _mm512_reduce_add_ps(rs" << r << ");\n";
  o << "  }\n"
    << "}\n";
  return o.str();
}

}  // namespace nfcuop::layout
