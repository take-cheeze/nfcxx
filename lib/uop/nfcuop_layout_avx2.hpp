// nfcuop layout, AVX2 emitter (docs/notes/uop-layout.md): the two GEMM variants of the layout model as C source.
//
//   std::string src = nfcuop::layout::emit_gemm_rowsum_c(GemmVariant::VecN, M, N, K);
//   // src defines   void nfc_gemm_rowsum(const float* A, const float* B, float* C, float* R, float* At);
//   // compile it with  cc -O2 -mavx2 -mfma -shared -fPIC
//
// Buffers (all float, the caller owns them):
//   A   M x K, row-major        B   K x N, row-major
//   C   the GEMM result, in the layout the model gives it: row-major M x N for VecN (lanes on N),
//       column-major (C[n*M + m]) for VecM (lanes on M)
//   R   M, the row sums of C
//   At  M x K scratch: VecM reads A transposed (the repair the model charges), so the kernel writes it first
//
// Shapes: VecN needs N % 8 == 0, VecM needs M % 8 == 0 (the lanes are full ymm vectors). The row sum is the same
// computation as the model's: VecN adds the N/8 vectors of a row, then one horizontal sum; VecM adds the N columns
// vertically for each 8 rows.
#pragma once
#include <cstdint>
#include <string>

namespace nfcuop::layout {

enum class GemmVariant : uint8_t { VecN, VecM };

// The C source of nfc_gemm_rowsum for the given shape. Throws std::invalid_argument when the shape does not fit the variant.
std::string emit_gemm_rowsum_c(GemmVariant v, int64_t M, int64_t N, int64_t K);

}  // namespace nfcuop::layout
