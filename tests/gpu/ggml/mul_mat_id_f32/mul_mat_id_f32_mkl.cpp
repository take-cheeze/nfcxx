// The F32 MUL_MAT_ID per-expert path of ggml-sycl (ggml/src/ggml-sycl/ggml-sycl.cpp, ggml_sycl_mul_mat_id around line 5430,
// the ne12 > 1 branch with the counting sort and the per-expert loop), with ggml's argument order and ggml's strides.
//
// The harness builds ggml-style tensors (ne[4], nb[4] in bytes) for src0 (expert weights, ne = K, M, n_as), src1
// (ne = K, ne11, n_tokens), ids (int32, ne = n_ids, n_tokens, nb[1] padded past n_ids * 4) and dst (ne = M, n_ids, n_tokens),
// then, as ggml does:
//   1. counts the routed rows per expert from ids (mmid_counting_sort_rows), and gathers each routed src1 row into a
//      contiguous buffer (k_copy_src1_to_contiguous: i11 = id % ne11, i12 = token);
//   2. for each expert with rows, calls oneapi::mkl::blas::column_major::gemm with ggml's arguments: trans, nontrans,
//      M (row_diff = ne01), N (src1_ncols = routed rows of the expert), K (ne10), alpha 1, src0 slice with lda = ne00 = K,
//      src1 rows with ldb = ne10 = K, beta 0, dst slice with ldc = ne0 = M;
//   3. scatters each output row back to dst at i1 * nb1 + i2 * nb2 (k_copy_dst_from_contiguous).
//
// What is under test: the oneMKL gemm (libmkl_sycl_blas, through the real oneMKL headers and the real oneAPI SYCL runtime).
// The host TU is compiled by the oneAPI compiler (icpx); no kernel in this file is emitted by nfcxx. The oracle is a host
// double-precision evaluation of every (slot, token) output row, out[t][s] = W[ids[t][s]] * src1[s % ne11][t], at 1e-4
// relative tolerance, on the device the environment selects (ONEAPI_DEVICE_SELECTOR; run.sh sets it per backend).
// Cases: 4 experts, 2 tokens, top-1 with an expert that gets no rows (ne11 = 1, broadcast src1); and 4 experts, 2 tokens,
// top-2 routing with an unused expert and src1 per slot (ne11 = n_ids). Guard slots past the dst tail must stay untouched.
//
// What it does NOT cover: the ggml dispatch itself (the MUL_MAT_ID fused mmvq path, the grouped dequant GEMM used for
// quantized src0, the per-expert ggml_sycl_mul_mat wrapper, the row-split); those run only inside libggml-sycl, which this
// harness does not link.
//
// MUTANT (built with -DMUTANT_PERTURB): one output element of the final dst is nudged after the scatter; the check must fail.
#include <sycl/sycl.hpp>
#include <oneapi/mkl/blas.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <utility>
#include <vector>

namespace mkl = oneapi::mkl;

// A fixed LCG over [-1, 1), so the run is repeatable.
static float mmid_next(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 2.0f - 1.0f;
}

// ggml-style tensor shape: element counts and byte strides, as ggml_tensor's ne and nb.
struct mmid_tensor {
    int64_t ne[4];
    size_t  nb[4];
};

struct mmid_case {
    const char * name;
    int64_t M, K, n_as, n_tokens, n_ids, ne11;
    int64_t ids_pad;                // extra int32 slots per ids row, so ids->nb[1] is not n_ids * 4
    std::vector<int32_t> ids;       // n_tokens rows of n_ids expert indices, row-major: ids[t * n_ids + s]
    uint32_t seed;
};

static int mmid_check(sycl::queue & q, const mmid_case & c) {
    const int64_t M = c.M, K = c.K, n_as = c.n_as, n_tokens = c.n_tokens, n_ids = c.n_ids, ne11 = c.ne11;

    // ggml's layouts. src0: [K, M, n_as], contiguous experts. src1: [K, ne11, n_tokens]. ids: [n_ids, n_tokens] padded rows.
    // dst: [M, n_ids, n_tokens].
    mmid_tensor src0 = { { K, M, n_as, 1 }, { 4, (size_t) K * 4, (size_t) M * K * 4, (size_t) M * K * 4 * n_as } };
    mmid_tensor src1 = { { K, ne11, n_tokens, 1 }, { 4, (size_t) K * 4, (size_t) ne11 * K * 4, (size_t) ne11 * K * 4 * n_tokens } };
    mmid_tensor ids  = { { n_ids, n_tokens, 1, 1 }, { 4, (size_t) (n_ids + c.ids_pad) * 4, 0, 0 } };
    ids.nb[2] = ids.nb[1] * n_tokens;
    mmid_tensor dst  = { { M, n_ids, n_tokens, 1 }, { 4, (size_t) M * 4, (size_t) n_ids * M * 4, (size_t) n_ids * n_tokens * M * 4 } };

    const size_t src0_bytes = src0.nb[3];
    const size_t src1_bytes = src1.nb[2] * n_tokens;
    const size_t ids_bytes  = ids.nb[2];
    const size_t dst_bytes  = dst.nb[3];
    const int64_t guard = 64;  // floats past the dst tail

    char * src0_buf = sycl::malloc_shared<char>(src0_bytes, q);
    char * src1_buf = sycl::malloc_shared<char>(src1_bytes, q);
    char * ids_buf  = sycl::malloc_shared<char>(ids_bytes, q);
    float * dst_buf = sycl::malloc_shared<float>(dst_bytes / 4 + guard, q);
    if (!src0_buf || !src1_buf || !ids_buf || !dst_buf) { printf("alloc failed\n"); return 1; }

    uint32_t state = c.seed;
    for (int64_t e = 0; e < n_as; e++)
        for (int64_t m = 0; m < M; m++)
            for (int64_t k = 0; k < K; k++)
                *(float *) (src0_buf + e * src0.nb[2] + m * src0.nb[1] + k * src0.nb[0]) = mmid_next(state);
    for (int64_t t = 0; t < n_tokens; t++)
        for (int64_t i11 = 0; i11 < ne11; i11++)
            for (int64_t k = 0; k < K; k++)
                *(float *) (src1_buf + t * src1.nb[2] + i11 * src1.nb[1] + k * src1.nb[0]) = mmid_next(state);
    std::memset(ids_buf, 0, ids_bytes);
    for (int64_t t = 0; t < n_tokens; t++)
        for (int64_t s = 0; s < n_ids; s++)
            *(int32_t *) (ids_buf + t * ids.nb[1] + s * ids.nb[0]) = c.ids[t * n_ids + s];
    for (int64_t i = 0; i < dst_bytes / 4 + guard; i++) dst_buf[i] = -7.0f;  // the guard tail must stay -7

    // 1. counting sort of the routed rows per expert (mmid_counting_sort_rows)
    std::vector<int64_t> expert_counts(n_as, 0);
    for (int64_t t = 0; t < n_tokens; t++)
        for (int64_t s = 0; s < n_ids; s++) {
            const int32_t e = *(const int32_t *) (ids_buf + t * ids.nb[1] + s * ids.nb[0]);
            if (e < 0 || e >= n_as) { printf("bad expert id %d\n", e); return 1; }
            expert_counts[e]++;
        }
    std::vector<int64_t> expert_offsets(n_as + 1, 0);
    for (int64_t e = 0; e < n_as; e++) expert_offsets[e + 1] = expert_offsets[e] + expert_counts[e];
    const int64_t n_routed = expert_offsets[n_as];  // ids->ne[1] * n_ids
    std::vector<int64_t> next = expert_offsets;
    std::vector<std::pair<int64_t, int64_t>> routed(n_routed);  // (slot id, token iid1) per contiguous row
    for (int64_t t = 0; t < n_tokens; t++)
        for (int64_t s = 0; s < n_ids; s++) {
            const int32_t e = *(const int32_t *) (ids_buf + t * ids.nb[1] + s * ids.nb[0]);
            routed[next[e]++] = { s, t };
        }

    // gather src1 rows contiguous, one K-row per routed row (k_copy_src1_to_contiguous)
    float * src1_c = sycl::malloc_shared<float>(n_routed * K, q);
    float * dst_c  = sycl::malloc_shared<float>(n_routed * M, q);
    if (!src1_c || !dst_c) { printf("alloc failed\n"); return 1; }
    for (int64_t r = 0; r < n_routed; r++) {
        const int64_t i11 = routed[r].first % ne11;
        const int64_t i12 = routed[r].second;
        const float * row = (const float *) (src1_buf + i11 * src1.nb[1] + i12 * src1.nb[2]);
        for (int64_t k = 0; k < K; k++) src1_c[r * K + k] = row[k];
    }

    // 2. one gemm per expert with rows, with ggml's arguments (ggml_sycl_op_mul_mat_sycl, column_major::gemm)
    const float alpha = 1.0f;
    const float beta  = 0.0f;
    for (int64_t e = 0; e < n_as; e++) {
        const int64_t N = expert_counts[e];
        if (N == 0) continue;
        const int64_t off = expert_offsets[e];
        const float * W = (const float *) (src0_buf + e * src0.nb[2]);
        const int64_t ne00 = K, ne10 = K, ldc = M;  // ldc = ne0 on the single device; ldb = ne10
        mkl::blas::column_major::gemm(q, mkl::transpose::trans, mkl::transpose::nontrans, M, N, K, alpha, W, ne00,
                                      src1_c + off * K, ne10, beta, dst_c + off * M, ldc).wait();
    }

    // 3. scatter back to dst at i1 * nb1 + i2 * nb2 (k_copy_dst_from_contiguous)
    for (int64_t r = 0; r < n_routed; r++) {
        const int64_t i1 = routed[r].first, i2 = routed[r].second;
        float * row = (float *) ((char *) dst_buf + i1 * dst.nb[1] + i2 * dst.nb[2]);
        for (int64_t m = 0; m < M; m++) row[m] = dst_c[r * M + m];
    }

#ifdef MUTANT_PERTURB
    // one output element of the final dst (token 0, slot 0, row 3), nudged well outside the tolerance
    *(float *) ((char *) dst_buf + 3 * dst.nb[0] + 0 * dst.nb[1] + 0 * dst.nb[2]) += 1e-2f;
#endif

    // oracle: every (slot, token) output row, evaluated in double on the host
    int64_t bad = 0, guard_writes = 0, checked = 0;
    double worst = 0.0;
    for (int64_t t = 0; t < n_tokens; t++)
        for (int64_t s = 0; s < n_ids; s++) {
            const int32_t e = *(const int32_t *) (ids_buf + t * ids.nb[1] + s * ids.nb[0]);
            const int64_t i11 = s % ne11;
            const float * x = (const float *) (src1_buf + i11 * src1.nb[1] + t * src1.nb[2]);
            const float * W = (const float *) (src0_buf + e * src0.nb[2]);
            for (int64_t m = 0; m < M; m++) {
                double want = 0.0;
                for (int64_t k = 0; k < K; k++) want += (double) W[m * K + k] * (double) x[k];
                const double got = (double) *(const float *) ((const char *) dst_buf + s * dst.nb[1] + t * dst.nb[2] + m * dst.nb[0]);
                const double err = std::fabs(got - want);
                const double tol = 1e-4 * std::max(1.0, std::fabs(want));
                if (!(err <= tol)) bad++;  // NaN fails too
                if (!std::isnan(err) && err > worst) worst = err;
                checked++;
            }
        }
    for (int64_t i = dst_bytes / 4; i < dst_bytes / 4 + guard; i++) guard_writes += dst_buf[i] != -7.0f;

    const bool ok = bad == 0 && guard_writes == 0;
    printf("mul_mat_id F32 %s: mismatches: %lld of %lld, guard writes: %lld of %lld, max abs err %.3g: %s\n",
           c.name, (long long) bad, (long long) checked, (long long) guard_writes, (long long) guard, worst,
           ok ? "ok" : "FAIL");

    sycl::free(src0_buf, q);
    sycl::free(src1_buf, q);
    sycl::free(ids_buf, q);
    sycl::free(dst_buf, q);
    sycl::free(src1_c, q);
    sycl::free(dst_c, q);
    return ok ? 0 : 1;
}

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    // 4 experts, 2 tokens, top-1: expert 1 and 3 get no rows; src1 is broadcast over slots (ne11 = 1)
    mmid_case top1 = { "4x2_top1", 17, 13, 4, 2, 1, 1, 1, { 2, 0 }, 2024u };
    // 4 experts, 2 tokens, top-2: expert 0 gets no rows, expert 1 gets two; src1 per slot (ne11 = n_ids = 2)
    mmid_case top2 = { "4x2_top2", 64, 64, 4, 2, 2, 2, 1, { 1, 3, 1, 2 }, 4048u };

    int failed = 0, checks = 0;
    failed += mmid_check(q, top1) != 0;
    checks++;
    failed += mmid_check(q, top2) != 0;
    checks++;
    printf("checks: %d, failed: %d\n", checks, failed);
    return failed != 0;
}
