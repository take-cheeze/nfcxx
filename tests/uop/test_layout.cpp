// nfcuop layout (lib/uop/nfcuop_layout.hpp, docs/notes/uop-layout.md): the AVX2 cost model's solver against the
// instruction counts worked out by hand for C = A*B with a row-sum epilogue (M = N = 64).
//   FMA count            M*N*K/8                 (both GEMM variants)
//   reduce-vertical      M*N/8                   (lanes on M)
//   reduce-horizontal    M*N/8 + 6*M             (lanes on N)
//   repair (transpose)   numel * 3/8             (an 8x8 block is 24 shuffles)
// The lane crossover is at K = 16: below it transposing A is cheaper, above it the horizontal sum is.
#undef NDEBUG  // keep the checks live in Release builds
#include "nfcuop_layout.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>

using namespace nfcuop::layout;

static int failures = 0;
#define CHECK(cond)                                                             \
  do {                                                                          \
    if (!(cond)) {                                                              \
      std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
      ++failures;                                                               \
    }                                                                           \
  } while (0)

static void k8_transposes_a() {
  // N-vectorized: 4096 + 512 + 384 = 4992. M-vectorized: 4096 + 512 + 192 (transpose A, 64*8*3/8) = 4800.
  Solution s = solve(gemm_rowsum(64, 64, 8));
  CHECK(s.feasible);
  CHECK(s.variant.size() == 2);
  CHECK(s.variant[0] == "avx2-vec-m");
  CHECK(s.variant[1] == "reduce-vertical");
  CHECK(s.cost == 4800.0);
  CHECK(s.repair_cost == 192.0);
  CHECK(s.repairs.size() == 1);
  if (s.repairs.size() == 1) {
    CHECK(s.repairs[0].op == "gemm");
    CHECK(s.repairs[0].tensor == "A");
    CHECK(s.repairs[0].from == Axis::Col);
    CHECK(s.repairs[0].to == Axis::Row);
  }
  CHECK(s.layout.at("A") == Axis::Col);  // A stays in memory as it arrived; the kernel reads a transposed copy
  CHECK(s.layout.at("C") == Axis::Row);
  CHECK(!s.layout.count("R"));           // the row sum has no lane constraint
}

static void k64_horizontal_sum() {
  // N-vectorized: 32768 + 512 + 384 = 33664, no repair. M-vectorized: 32768 + 512 + 1536 (transpose A) = 34816.
  Solution s = solve(gemm_rowsum(64, 64, 64));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-vec-n");
  CHECK(s.variant[1] == "reduce-horizontal");
  CHECK(s.cost == 33664.0);
  CHECK(s.repairs.empty());
  CHECK(s.repair_cost == 0.0);
  CHECK(s.layout.at("B") == Axis::Col);
  CHECK(s.layout.at("C") == Axis::Col);
}

static void k16_tie_first_variant_wins() {
  // Both (vec-n, horizontal) and (vec-m, vertical) come to 8192 + 512 + 384 = 9088 (the transpose of A is 64*16*3/8 = 384).
  // Enumeration varies op 0 fastest, so (vec-m, vertical) is reached first and is the one kept.
  Solution s = solve(gemm_rowsum(64, 64, 16));
  CHECK(s.feasible);
  CHECK(s.cost == 9088.0);
  CHECK(s.variant[0] == "avx2-vec-m");
  CHECK(s.variant[1] == "reduce-vertical");
}

static void no_variant_is_infeasible() {
  Problem p = gemm_rowsum(8, 8, 8);
  p.ops[1].variants.clear();
  CHECK(!solve(p).feasible);
}

static void target_costs_are_used() {
  // With free transposes the horizontal sum is never worth its 6*M extra: the vertical row sum wins. Both GEMM
  // variants then cost FMA + 512 (vec-n with a free transpose of C, vec-m with a free transpose of A), so the tie
  // goes to vec-n, which the enumeration reaches first.
  Avx2F32 cheap;
  cheap.transpose_instr_per_elem = 0.0;
  Solution s = solve(gemm_rowsum(64, 64, 64, cheap));  // the target goes into the Problem
  CHECK(s.feasible);
  CHECK(s.variant[1] == "reduce-vertical");
  CHECK(s.cost == 32768.0 + 512.0);
  CHECK(s.repair_cost == 0.0);
}

int main() {
  k8_transposes_a();
  k64_horizontal_sum();
  k16_tie_first_variant_wins();
  no_variant_is_infeasible();
  target_costs_are_used();
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("test_layout: all checks passed\n");
  return 0;
}
