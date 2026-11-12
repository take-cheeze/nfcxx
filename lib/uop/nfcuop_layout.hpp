// nfcuop layout (stage 8, docs/notes/uop-layout.md): instruction-visible layout of 2-D f32 tensors on the AVX2 target.
//
// Layout model from Arknife (the paper's name for the system): Ma, Chen, Li, Luo, Xiao, Zheng, Li, Liang. "Retargetable Compilation for Tensor Kernels via a Unified Layout Abstraction". arXiv:2611.13741 [cs.PL], 2026. https://arxiv.org/abs/2611.13741
//
//   A tensor's layout is the logical axis that the vector lanes hold (8 consecutive elements of that axis per ymm).
//   An op has variants (instruction sequences); a variant declares the lane axis each input must be in (absent = any,
//   for example a broadcast operand) and the lane axis its output comes out in, plus its intrinsic instruction count.
//   When a tensor is in the wrong lane axis for a consumer, a repair is needed (an 8x8 transpose, costed per element).
//   solve() enumerates the variant choices and returns the one with the fewest instructions, repairs included.
//   A tensor in Row lanes (the lanes on M) is also held in a storage, Strided or Blocked8; solve() enumerates it too
//   and charges the storage cost of each Row-lane tensor (see Avx2F32).
//
// This is a cost model, not a measurement: the numbers come from the instruction counts written in the target
// description (Avx2F32) and in gemm_rowsum(). See docs/notes/uop-layout.md for the model and what it leaves out.
#pragma once
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace nfcuop::layout {

// The logical axis of a 2-D tensor that the lanes hold. Row-major storage has its lanes on Col.
enum class Axis : uint8_t { Row = 0, Col = 1 };

// How a Row-lane tensor (lanes on M) is kept in memory. Strided: column by column, so the lanes of one load or store are
// a row length apart. Blocked8: 8-row blocks, each contiguous. Only Row-lane tensors have a storage choice.
enum class Storage : uint8_t { Strided = 0, Blocked8 = 1 };

// The AVX2 f32 target (ymm: 256 bits, 8 floats).
//
// Storage cost: each Row-lane tensor the plan holds (a GEMM output in Row lanes, or a copy a repair makes in Row lanes)
// adds  numel * strided_instr_per_elem  if it is Strided, and  numel * blocked_instr_per_elem  if it is Blocked8.
// The constants and their sources are in docs/notes/uop-layout.md ("Storage of the lanes-on-M tensors").
struct Avx2F32 {
  int lanes = 8;
  double transpose_instr_per_elem = 3.0 / 8.0;  // an 8x8 f32 transpose is 24 shuffles on 64 elements
  double hsum_instr_per_row = 6.0;              // horizontal sum of one ymm: 3 shuffles and 3 adds
  // Strided penalty, per element, in the model's instruction units. From the 40% gap of strided vec-m over vec-n at
  // K = 8, M = N = 256: (1.40 - 0.99) * 75264 / 67584 = 0.46, with 0.99 the model's blocked vec-m over vec-n and 67584
  // the elements of A^T and C. It fits K = 8, 24 and 32 and misses K = 16 and 64 (see the note).
  double strided_instr_per_elem = 0.46;
  // Blocked cost, per element. Zero: the blocked kernel matches the model's count within the timing noise at K = 8 to 64.
  double blocked_instr_per_elem = 0.0;
};

struct Tensor {
  std::string name;
  int64_t rows = 0, cols = 1;                   // 2-D; a vector is rows x 1
  std::optional<Axis> given;                    // an input: the lane axis it arrives in (memory). Unset: an op produces it
  int64_t numel() const { return rows * cols; }
};

// One way to compute an op: the lane axis each input must be in (absent = any) and the one its output is produced in
// (absent = none, the output has no lane constraint), and the instructions of the variant itself (repairs not included).
struct Variant {
  std::string name;
  std::map<std::string, Axis> requires_lane;
  std::map<std::string, Axis> produces_lane;
  double instructions = 0;
};

struct Op {
  std::string name;
  std::vector<std::string> inputs;
  std::string output;                           // one output tensor
  std::vector<Variant> variants;                // no variants: the problem is infeasible
};

struct Problem {
  Avx2F32 target;                               // the costs of the repairs (and of whatever the variants count)
  std::vector<Tensor> tensors;
  std::vector<Op> ops;                          // in topological order
};

struct Repair {
  std::string op;                               // the consumer that needed it
  std::string tensor;
  Axis from, to;
  double instructions = 0;
};

struct Solution {
  bool feasible = false;
  double cost = 0;                              // variant instructions + repair instructions + storage_cost
  double repair_cost = 0;
  double storage_cost = 0;                      // the storage term of cost (Avx2F32)
  std::vector<std::string> variant;             // chosen variant name, per op
  std::map<std::string, Axis> layout;           // lane axis of each tensor that has one
  std::vector<Repair> repairs;
  // Storage of each Row-lane tensor the plan holds: a produced output, or the copy a repair makes, keyed by tensor name
  // (so "A" is the transposed copy of A, while layout["A"] is still Col, the arrival layout).
  std::map<std::string, Storage> storage;
};

// Brute force over the variant choices (the product of the variant counts), and for each choice over the storage of
// its Row-lane tensors. Ties: the first minimum in the enumeration order, where op 0's index is the fastest-varying one,
// and within one variant choice the all-Strided storage comes first.
Solution solve(const Problem& p);

// C[M,N] = A[M,K] * B[K,N] (A and B arrive row-major), then R[M] = sum over the columns of C (the epilogue).
// Variants: "avx2-vec-n" (lanes on N: C and B in Col, broadcast A) and "avx2-vec-m" (lanes on M: A in Row, broadcast B);
// the row sum is "reduce-vertical" (lanes on M, adds across ymm registers) or "reduce-horizontal" (lanes on N, a
// horizontal sum per row). The FMA count is the same for both GEMM variants, so it is included as a common cost.
Problem gemm_rowsum(int64_t M, int64_t N, int64_t K, const Avx2F32& target = {});  // target is stored in the Problem

const char* axis_name(Axis a);

}  // namespace nfcuop::layout
