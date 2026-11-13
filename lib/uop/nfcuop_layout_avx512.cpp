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

std::string emit_gemm_rowsum_packed512_mt_c(int64_t M, int64_t N, int64_t K, int mr) {
  if (M < 1 || N < 1 || K < 1) throw std::invalid_argument("emit_gemm_rowsum_packed512_mt_c: sizes must be positive");
  if (mr != 4 && mr != 6) throw std::invalid_argument("emit_gemm_rowsum_packed512_mt_c: the row tile is 4 or 6");
  if (M % mr != 0) throw std::invalid_argument("emit_gemm_rowsum_packed512_mt_c: needs M % mr == 0");
  if (N % 32 != 0) throw std::invalid_argument("emit_gemm_rowsum_packed512_mt_c: needs N % 32 == 0");
  std::ostringstream o;
  o << "#include <immintrin.h>\n#include <pthread.h>\n#include <stdint.h>\n";
  // Each job packs a range of panels (phase 1) and runs a range of row tiles (phase 2). The phases are separate thread
  // launches, so no barrier is needed (pthread_barrier_t is not on macOS).
  o << "typedef struct { const float* A; const float* B; float* C; float* R; float* Bp; int64_t p0, p1, i0, i1; } nfc_job;\n"
    << "static void* nfc_pack(void* arg) {\n"
    << "  nfc_job* j = (nfc_job*)arg;\n"
    << "  for (int64_t p = j->p0; p < j->p1; ++p)\n"
    << "    for (int64_t k = 0; k < " << K << "; ++k)\n"
    << "      for (int64_t q = 0; q < 32; ++q) j->Bp[p * " << K * 32 << " + k * 32 + q] = j->B[k * " << N << " + p * 32 + q];\n"
    << "  return 0;\n"
    << "}\n"
    << "static void* nfc_tiles(void* arg) {\n"
    << "  nfc_job* j = (nfc_job*)arg;\n"
    << "  const float* A = j->A; const float* Bp = j->Bp; float* C = j->C; float* R = j->R;\n"
    << "  for (int64_t i = j->i0; i < j->i1; i += " << mr << ") {\n";
  for (int r = 0; r < mr; ++r) o << "    __m512 rs" << r << " = _mm512_setzero_ps();\n";
  o << "    for (int64_t n = 0; n < " << N << "; n += 32) {\n"
    << "      const float* bn = Bp + (n / 32) * " << K * 32 << ";\n";
  for (int r = 0; r < mr; ++r) o << "      __m512 c" << r << "0 = _mm512_setzero_ps(), c" << r << "1 = _mm512_setzero_ps();\n";
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
    << "  return 0;\n"
    << "}\n";
  o << "void nfc_gemm_rowsum(const float* A, const float* B, float* C, float* R, float* Bp, int nthreads) {\n"
    << "  int64_t panels = " << (N / 32) << ", tiles = " << (M / mr) << ";\n"
    << "  if (nthreads < 1) nthreads = 1;\n"
    << "  if (nthreads > 64) nthreads = 64;\n"
    << "  if (nthreads > tiles) nthreads = (int)tiles;\n"
    << "  if (nthreads > panels) nthreads = (int)panels;\n"
    << "  nfc_job jobs[64];\n"
    << "  pthread_t th[64];\n"
    << "  int started[64];\n"
    << "  for (int t = 0; t < nthreads; ++t) {\n"
    << "    jobs[t].A = A; jobs[t].B = B; jobs[t].C = C; jobs[t].R = R; jobs[t].Bp = Bp;\n"
    << "    jobs[t].p0 = panels * t / nthreads; jobs[t].p1 = panels * (t + 1) / nthreads;\n"
    << "    jobs[t].i0 = (tiles * t / nthreads) * " << mr << "; jobs[t].i1 = (tiles * (t + 1) / nthreads) * " << mr << ";\n"
    << "  }\n"
    << "  /* phase 1: pack B, one range of panels per thread */\n"
    << "  for (int t = 1; t < nthreads; ++t) started[t] = pthread_create(&th[t], 0, nfc_pack, &jobs[t]) == 0;\n"
    << "  nfc_pack(&jobs[0]);\n"
    << "  for (int t = 1; t < nthreads; ++t) {\n"
    << "    if (started[t]) pthread_join(th[t], 0);\n"
    << "    else nfc_pack(&jobs[t]);\n"
    << "  }\n"
    << "  /* phase 2: the row tiles, one range per thread */\n"
    << "  for (int t = 1; t < nthreads; ++t) started[t] = pthread_create(&th[t], 0, nfc_tiles, &jobs[t]) == 0;\n"
    << "  nfc_tiles(&jobs[0]);\n"
    << "  for (int t = 1; t < nthreads; ++t) {\n"
    << "    if (started[t]) pthread_join(th[t], 0);\n"
    << "    else nfc_tiles(&jobs[t]);\n"
    << "  }\n"
    << "}\n";
  return o.str();
}

}  // namespace nfcuop::layout
