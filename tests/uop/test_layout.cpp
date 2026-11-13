// nfcuop layout (lib/uop/nfcuop_layout.hpp, docs/notes/uop-layout.md): the AVX2 cost model's solver against the
// instruction counts worked out by hand for C = A*B with a row-sum epilogue (M = N = 64).
//   FMA count            M*N*K/8                 (both GEMM variants)
//   reduce-vertical      M*N/8                   (lanes on M)
//   reduce-horizontal    M*N/8 + 6*M             (lanes on N)
//   repair (transpose)   numel * 3/8             (an 8x8 block is 24 shuffles)
//   storage (Row lanes)  numel * 0.46 if Strided, 0 if Blocked8 (Avx2F32; the 0.46 is from the K = 8 timing)
// The lane crossover is at K = 16: below it transposing A is cheaper, above it the horizontal sum is.
// The first five checks keep their totals: under the default target the Row-lane tensors are Blocked8, which costs nothing.
#undef NDEBUG  // keep the checks live in Release builds
#include "nfcuop_layout.hpp"

#include <cmath>
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

static void k8_blocked_storage_wins() {
  // M = N = 256, K = 8. vec-m: FMA 256*256*8/8 = 65536, transpose of A 256*8*3/8 = 768, reduce-vertical 256*256/8 = 8192:
  // 74496. vec-n: 65536 + 8192 + 6*256 = 75264. The Row-lane tensors are A^T (2048 elements) and C (65536). Blocked costs
  // 0 per element, so Blocked8 is chosen for both. A strided copy would add 0.46 * 67584 = 31089 (see the zero test below).
  Solution s = solve(gemm_rowsum(256, 256, 8));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-vec-m");
  CHECK(s.variant[1] == "reduce-vertical");
  CHECK(s.cost == 74496.0);
  CHECK(s.storage_cost == 0.0);
  CHECK(s.storage.size() == 2);
  CHECK(s.storage.at("A") == Storage::Blocked8);  // the transposed copy of A
  CHECK(s.storage.at("C") == Storage::Blocked8);
}

static void k8_zero_penalty_keeps_strided() {
  // The same problem with no strided penalty: Strided and Blocked8 cost the same, and the all-Strided choice comes first.
  Avx2F32 free_strided;
  free_strided.strided_instr_per_elem = 0.0;
  Solution s = solve(gemm_rowsum(256, 256, 8, free_strided));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-vec-m");
  CHECK(s.cost == 74496.0);
  CHECK(s.storage_cost == 0.0);
  CHECK(s.storage.at("A") == Storage::Strided);
  CHECK(s.storage.at("C") == Storage::Strided);
}

static void k64_storage_does_not_change_choice() {
  // M = N = 256, K = 64: vec-n is 524288 + 8192 + 1536 = 534016 with no Row-lane tensor. vec-m with blocked storage would
  // be 524288 + 8192 + 6144 = 538624, so the choice stays vec-n, and no storage is reported.
  Solution s = solve(gemm_rowsum(256, 256, 64));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-vec-n");
  CHECK(s.variant[1] == "reduce-horizontal");
  CHECK(s.cost == 534016.0);
  CHECK(s.storage_cost == 0.0);
  CHECK(s.storage.empty());
}

static void blocked_cost_keeps_strided() {
  // M = N = 64, K = 8: vec-m is 4800 with no storage term, and vec-n is 4992. With a strided penalty of 0.01 per element
  // and a blocked cost of 0.02, Strided costs 0.01 * (512 + 4096) = 46.08 and Blocked8 costs 92.16, so Strided is kept.
  Avx2F32 t;
  t.strided_instr_per_elem = 0.01;
  t.blocked_instr_per_elem = 0.02;
  Solution s = solve(gemm_rowsum(64, 64, 8, t));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-vec-m");
  CHECK(std::fabs(s.storage_cost - 46.08) < 1e-9);
  CHECK(std::fabs(s.cost - 4846.08) < 1e-9);
  CHECK(s.storage.at("A") == Storage::Strided);
  CHECK(s.storage.at("C") == Storage::Strided);
}

static void packed_chosen_when_shape_fits() {
  // M = 504, N = 512, K = 512 (504 % 6 == 0, 512 % 16 == 0). fma = 504*512*512/8 = 16515072; the packed kernel's FMA cost is
  // fma * 0.18. B is packed into Panel (512*512 elements at 0.25 each = 65536). The row sum is horizontal (C in Col
  // lanes): 504*512/8 + 6*504 = 35280. Total 2972712.96 + 65536 + 35280.
  Solution s = solve(gemm_rowsum(504, 512, 512));
  CHECK(s.feasible);
  CHECK(s.variant.size() == 2);
  CHECK(s.variant[0] == "avx2-packed-n");
  CHECK(s.variant[1] == "reduce-horizontal");
  CHECK(s.repairs.empty());
  CHECK(s.storage.at("B") == Storage::Panel);
  CHECK(s.storage.size() == 1);
  CHECK(std::fabs(s.storage_cost - 65536.0) < 1e-6);
  CHECK(std::fabs(s.cost - (16515072.0 * 0.18 + 65536.0 + 35280.0)) < 1e-6);
  CHECK(s.layout.at("C") == Axis::Col);
}

static void packed_absent_when_shape_misses() {
  // 500 % 16 != 0 and 64 % 6 != 0: the packed kernel is not a candidate, so the GEMM has the two layout variants only.
  CHECK(gemm_rowsum(504, 500, 512).ops[0].variants.size() == 2);
  CHECK(gemm_rowsum(64, 64, 64).ops[0].variants.size() == 2);
  CHECK(gemm_rowsum(504, 512, 512).ops[0].variants.size() == 3);
  Solution s = solve(gemm_rowsum(504, 500, 512));
  CHECK(s.feasible);
  CHECK(s.variant[0] != "avx2-packed-n");
  CHECK(!s.storage.count("B"));
}

static void packing_cost_is_charged() {
  // With no packing cost the packed plan is cheaper by exactly the Panel storage: 512*512 * 0.25 = 65536.
  Avx2F32 free_panel;
  free_panel.panel_instr_per_elem = 0.0;
  Solution with = solve(gemm_rowsum(504, 512, 512));
  Solution without = solve(gemm_rowsum(504, 512, 512, free_panel));
  CHECK(std::fabs((with.cost - without.cost) - 65536.0) < 1e-6);
  CHECK(without.storage_cost == 0.0);
  CHECK(without.variant[0] == "avx2-packed-n");
  CHECK(without.storage.at("B") == Storage::Panel);
}

static void packed_needs_its_factor() {
  // With the register-blocked factor at 1 the packed kernel costs fma + 65536 + 35280, more than naive vec-n's fma + 35280,
  // so the plan keeps the naive kernel and stores nothing in Panel. The choice is the fitted factor's, nothing more.
  Avx2F32 unblocked;
  unblocked.register_blocked_fma_factor = 1.0;
  Solution s = solve(gemm_rowsum(504, 512, 512, unblocked));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-vec-n");
  CHECK(s.storage.empty());
}

static void threads_default_to_one() {
  // max_threads defaults to 1, so the packed plan is single-threaded and its cost is the unthreaded one.
  Solution s = solve(gemm_rowsum(504, 512, 512));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-packed-n");
  CHECK(s.threads == 1);
}

static void threads_chosen_when_they_pay() {
  // With up to 8 threads, the packed FMA work W = 504*512*512/8 * 0.18 = 2972712.96 splits as W * (0.10 + 0.90 / t) + 154000 * (t - 1):
  // 2 threads 1788992, 4 threads 1428131.71, 8 threads 1709779. Four is the minimum. The plan's cost is that plus the
  // packing copy (65536) and the row sum (35280).
  Avx2F32 t;
  t.max_threads = 8;
  Solution s = solve(gemm_rowsum(504, 512, 512, t));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-packed-n");
  CHECK(s.threads == 4);
  CHECK(std::fabs(s.cost - (2972712.96 * 0.325 + 154000.0 * 3 + 65536.0 + 35280.0)) < 1e-3);
}

static void threads_not_chosen_for_small_work() {
  // 48 x 64 x 17: the packed FMA work is 1175 instructions, far below one thread spawn, so one thread is kept.
  Avx2F32 t;
  t.max_threads = 8;
  Solution s = solve(gemm_rowsum(48, 64, 17, t));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx2-packed-n");
  CHECK(s.threads == 1);
}

static void avx512_packed_chosen() {
  // AVX-512 target: 16 lanes, 32-column tiles. M = 504, N = 512, K = 512 (504 % 6 == 0, 512 % 32 == 0). fma = 504*512*512/16
  // = 8257536, packed at 0.18 is 1486356.48. B in Panel (512*512 at 2/16 = 32768). Row sum horizontal: 504*512/16 + 8*504
  // = 16128 + 4032. Only the packed variant exists on this target.
  F32Target t = avx512_f32();
  Solution s = solve(gemm_rowsum(504, 512, 512, t));
  CHECK(s.feasible);
  CHECK(s.variant.size() == 2);
  CHECK(s.variant[0] == "avx512-packed-n");
  CHECK(s.variant[1] == "reduce-horizontal");
  CHECK(s.storage.at("B") == Storage::Panel);
  CHECK(std::fabs(s.storage_cost - 32768.0) < 1e-6);
  CHECK(std::fabs(s.cost - (8257536.0 * 0.18 + 32768.0 + 20160.0)) < 1e-3);
  CHECK(gemm_rowsum(504, 512, 512, t).ops[0].variants.size() == 1);
}

static void avx512_infeasible_when_shape_misses() {
  // 500 % 32 != 0 and there is no VecN or VecM on AVX-512, so no variant computes the GEMM.
  Solution s = solve(gemm_rowsum(504, 500, 512, avx512_f32()));
  CHECK(!s.feasible);
}

static void emitted_row_sum_wins_the_tie() {
  // AVX-512, M = 12, N = 32, K = 5: the vertical row sum after the packed kernel would transpose C (384 * 0.25 = 96),
  // the horizontal one costs 8 per row (96): a tie. The packed kernel's pair with the vertical sum is not a plan, so the
  // horizontal one is chosen.
  Solution s = solve(gemm_rowsum(12, 32, 5, avx512_f32()));
  CHECK(s.feasible);
  CHECK(s.variant[0] == "avx512-packed-n");
  CHECK(s.variant[1] == "reduce-horizontal");
  CHECK(s.repairs.empty());
}

int main() {
  k8_transposes_a();
  k64_horizontal_sum();
  k16_tie_first_variant_wins();
  no_variant_is_infeasible();
  target_costs_are_used();
  k8_blocked_storage_wins();
  k8_zero_penalty_keeps_strided();
  k64_storage_does_not_change_choice();
  blocked_cost_keeps_strided();
  packed_chosen_when_shape_fits();
  packed_absent_when_shape_misses();
  packing_cost_is_charged();
  packed_needs_its_factor();
  threads_default_to_one();
  threads_chosen_when_they_pay();
  threads_not_chosen_for_small_work();
  avx512_packed_chosen();
  avx512_infeasible_when_shape_misses();
  emitted_row_sum_wins_the_tie();
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("test_layout: all checks passed\n");
  return 0;
}
