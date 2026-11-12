// nfcuop layout, AVX-512 emitter (docs/notes/uop-layout.md): the packed, register-blocked GEMM with the row-sum epilogue,
// on 16-lane f32 vectors (zmm). The AVX2 version is in nfcuop_layout_avx2.hpp; this one follows it.
//
//   std::string src = nfcuop::layout::emit_gemm_rowsum_packed512_c(M, N, K, mr);
//   // src defines   void nfc_gemm_rowsum(const float* A, const float* B, float* C, float* R, float* Bp);
//   // compile it with  cc -O2 -mavx512f -mfma -shared -fPIC
//
// The tile is mr rows by 32 columns (two zmm per row), with B packed into 32-column panels. mr is 4 or 6, so the
// accumulators are 8 or 12 zmm of the 32. Requires M % mr == 0 and N % 32 == 0. Bp is scratch of K * N floats.
#pragma once
#include <cstdint>
#include <string>

namespace nfcuop::layout {

std::string emit_gemm_rowsum_packed512_c(int64_t M, int64_t N, int64_t K, int mr = 6);

}  // namespace nfcuop::layout
