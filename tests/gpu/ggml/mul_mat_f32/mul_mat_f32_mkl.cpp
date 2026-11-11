// The F32 x F32 mat-mul call of ggml-sycl's ggml_sycl_op_mul_mat_sycl (ggml/src/ggml-sycl/ggml-sycl.cpp, the final
// branch, around line 3227), made with the same arguments: oneapi::mkl::blas::column_major::gemm(trans, nontrans, row_diff,
// src1_ncols, ne10, alpha, src0, lda = ne00, src1, ldb = ne10, beta, dst, ldc = ne0), alpha 1, beta 0.
//
// What is under test: the oneMKL gemm itself (libmkl_sycl_blas, reached through the real oneMKL headers and the real
// oneAPI SYCL runtime). This TU is compiled by nfcxx's host pass, but the kernel that does the arithmetic is MKL's, not
// nfcxx's: no kernel in this file is emitted by nfcxx. The harness checks the result against a host double-precision
// oracle at 1e-4 relative tolerance, on the device the environment selects (ONEAPI_DEVICE_SELECTOR; run.sh sets it per
// backend). Shapes: M x N x K = 17 x 13 x 9 and 64 x 64 x 64. Guard slots past the dst tail must stay untouched.
//
// What it does NOT cover: the ggml dispatch itself (ggml_sycl_op_mul_mat_sycl, the row-split, the type conversions, the
// ldc == ne0 choice made for a single device); those run only inside libggml-sycl, which this harness does not link.
//
// MUTANT (built with -DMUTANT_PERTURB): one output element is nudged after gemm returns; the check must then fail.
#include <sycl/sycl.hpp>
#include <oneapi/mkl/blas.hpp>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace mkl = oneapi::mkl;

// A fixed LCG over [-1, 1), so the run is repeatable.
static float mm_next(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 2.0f - 1.0f;
}

// One check. src0 is M rows of K values (row i at src0 + i * K, the ggml layout with ne00 = K); src1 is N rows of K values
// (row j at src1 + j * K, ne10 = K); dst has ldc = M and column j at dst + j * M (ne0 = M). Column-major, this is
// C(M x N) = A^T B with A (K x M, lda = K) and B (K x N, ldb = K), exactly as ggml calls it.
static int mm_check(sycl::queue & q, int64_t M, int64_t N, int64_t K, uint32_t seed, const char * shape_name) {
    const int64_t ldc  = M;
    const int64_t guard = 64;
    float * src0 = sycl::malloc_shared<float>(M * K, q);
    float * src1 = sycl::malloc_shared<float>(N * K, q);
    float * dst  = sycl::malloc_shared<float>(ldc * N + guard, q);
    if (!src0 || !src1 || !dst) { printf("alloc failed\n"); return 1; }

    uint32_t state = seed;
    for (int64_t i = 0; i < M * K; i++) src0[i] = mm_next(state);
    for (int64_t i = 0; i < N * K; i++) src1[i] = mm_next(state);
    for (int64_t i = 0; i < ldc * N + guard; i++) dst[i] = -7.0f;  // the tail past ldc*N must stay untouched

    const float alpha = 1.0f;
    const float beta  = 0.0f;
    mkl::blas::column_major::gemm(q, mkl::transpose::trans, mkl::transpose::nontrans, M, N, K, alpha, src0, K, src1, K,
                                  beta, dst, ldc).wait();

#ifdef MUTANT_PERTURB
    dst[ldc + 3] += 1e-2f;  // one output element, well outside the tolerance
#endif

    int64_t bad = 0, guard_writes = 0;
    double worst = 0.0;
    for (int64_t j = 0; j < N; j++) {
        for (int64_t i = 0; i < M; i++) {
            double want = 0.0;
            for (int64_t k = 0; k < K; k++) want += (double) src0[i * K + k] * (double) src1[j * K + k];
            const double got = (double) dst[j * ldc + i];
            const double err = std::fabs(got - want);
            const double tol = 1e-4 * std::max(1.0, std::fabs(want));
            if (!(err <= tol)) bad++;  // NaN fails too
            if (!std::isnan(err) && err > worst) worst = err;
        }
    }
    for (int64_t i = ldc * N; i < ldc * N + guard; i++) guard_writes += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard_writes == 0;
    printf("mul_mat F32 %s: mismatches: %lld of %lld, guard writes: %lld of %lld, max abs err %.3g: %s\n",
           shape_name, (long long) bad, (long long) (M * N), (long long) guard_writes, (long long) guard, worst,
           ok ? "ok" : "FAIL");
    sycl::free(src0, q);
    sycl::free(src1, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    int failed = 0, checks = 0;
    failed += mm_check(q, 17, 13, 9, 2024u, "17x13x9") != 0;
    checks++;
    failed += mm_check(q, 64, 64, 64, 4048u, "64x64x64") != 0;
    checks++;
    printf("checks: %d, failed: %d\n", checks, failed);
    return failed != 0;
}
