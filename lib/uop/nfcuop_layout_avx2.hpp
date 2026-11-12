// nfcuop layout, AVX2 emitter (docs/notes/uop-layout.md): the two GEMM variants of the layout model as C source.
//
// Layout model from Arknife (the paper's name for the system): Ma, Chen, Li, Luo, Xiao, Zheng, Li, Liang. "Retargetable Compilation for Tensor Kernels via a Unified Layout Abstraction". arXiv:2611.13741 [cs.PL], 2026. https://arxiv.org/abs/2611.13741
//
//   std::string src = nfcuop::layout::emit_gemm_rowsum_c(GemmVariant::VecN, M, N, K);
//   // src defines   void nfc_gemm_rowsum(const float* A, const float* B, float* C, float* R, float* At);
//   // compile it with  cc -O2 -mavx2 -mfma -shared -fPIC
//
// Buffers (all float, the caller owns them):
//   A   M x K, row-major        B   K x N, row-major
//   C   the GEMM result, in the layout the model gives it: row-major M x N for VecN (lanes on N).
//       For VecM (lanes on M) it depends on the storage:
//         Strided  (default): column-major, C[n*M + m]
//         Blocked8:           8-row blocks, each N x 8 with the rows inside a block contiguous:
//                             C[(m - m%8)*N + n*8 + m%8]
//   R   M, the row sums of C
//   At  M x K scratch: VecM reads A transposed (the repair the model charges), so the kernel writes it first.
//       Strided: At[k*M + m]. Blocked8: 8-row blocks, At[(m - m%8)*K + k*8 + m%8].
//
// Shapes: VecN needs N % 8 == 0, VecM needs M % 8 == 0 (the lanes are full ymm vectors). The row sum is the same
// computation as the model's: VecN adds the N/8 vectors of a row, then one horizontal sum; VecM adds the N columns
// vertically for each 8 rows.
//
// The VecM transpose is an 8x8 block kernel (24 shuffles per 64 elements, the cost the model charges) when
// simd_transpose is true, and a scalar loop otherwise. The scalar form is kept so the two can be timed against each other.
#pragma once
#include <cstdint>
#include <string>

namespace nfcuop::layout {

enum class GemmVariant : uint8_t { VecN, VecM };

// How VecM lays out its lanes-on-M data (A transposed and the result C). Blocked8 is the layout that the experiments
// in docs/notes/uop-layout.md found to remove the M-vectorized penalty; VecN ignores it.
enum class Storage : uint8_t { Strided, Blocked8 };

// The C source of nfc_gemm_rowsum for the given shape. Throws std::invalid_argument when the shape does not fit the variant.
std::string emit_gemm_rowsum_c(GemmVariant v, int64_t M, int64_t N, int64_t K, bool simd_transpose = true,
                               Storage storage = Storage::Strided);

}  // namespace nfcuop::layout
