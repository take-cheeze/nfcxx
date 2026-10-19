// The real ggml-sycl top-k radix kernel (ggml/src/ggml-sycl/topk-radix.cpp, unchanged), compiled as this program's own TU
// through the nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (top_k/run.sh puts a mutant copy's
// dir first). The entry point is the public ggml_sycl_top_k_radix, the k > SYCL_TOP_K_SCAN_MERGE_MAX_K path that
// ggml_sycl_op_top_k dispatches to; the scan-merge path (k <= 8) lives in ggml-sycl.cpp as a static function and is not
// reachable from a separate TU, so it is not covered here. The ggml helpers and the backend's ggml_sycl_info() come from
// libggml-sycl.so.
//
// Two shapes, F32 input, int32 output of k indices per row (no particular order), k < row length in both:
//   A  1000 cols x 3 rows, k = 16: one work-group per row, distinct values
//   B  70000 cols x 2 rows, k = 32: the split path (the row is spread over several groups and merged in four launches),
//      with heavy ties (64 distinct values), so pivot-equal columns decide the boundary
//
// Oracle (host, float compares only): per row, the k-th largest value kth. The result is valid iff its k
// indices are in range and distinct, every one has value >= kth, and exactly as many of them have value > kth as the row
// has. Ties at kth may be broken either way: upstream fills the pivot-equal tail in the order its atomics land, which is
// not deterministic across work-items, so the oracle does not pin which pivot-equal columns are chosen.
//
// Output: 64 guard slots past the k * nrows outputs must stay untouched. The driver (top_k/run.sh) passes the build flags.
#include "topk-radix.cpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <vector>

// Values in [-4, 4): a fixed LCG so the run is repeatable. ties: quantized to 1/8, 64 distinct values.
static float next_value(uint32_t & state, bool ties) {
    state = state * 1664525u + 1013904223u;
    const float u = (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000;
    const float v = -4.0f + 8.0f * u;
    return ties ? std::floor(v * 8.0f) / 8.0f : v;
}

// The pool the split path allocates its state from (ctx.pool() is inline in common.hpp and calls new_pool_for_device). The
// backend's own new_pool_for_device, in libggml-sycl.so, takes a queue of the oneAPI ABI (sycl::_V1::queue), which the nfcxx
// queue type here does not match, so the link cannot bind it; this TU defines the function itself. It is a plain USM
// allocator with no reuse, which changes only the allocation, not the kernel under test.
namespace {
struct top_k_test_pool : ggml_sycl_pool {
    sycl::queue * q = nullptr;
    void * alloc(size_t size, size_t * actual_size) override {
        *actual_size = size;
        return sycl::malloc_shared<char>(size ? size : 1, *q);
    }
    void free(void * ptr, size_t) override { sycl::free(ptr, *q); }
};
}

std::unique_ptr<ggml_sycl_pool> ggml_backend_sycl_context::new_pool_for_device(queue_ptr qptr, int) {
    auto p = std::make_unique<top_k_test_pool>();
    p->q = qptr;
    return p;
}

// One check: the top-k of nrows rows of ncols columns, through the real ggml_sycl_top_k_radix.
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, int64_t ncols, int64_t nrows, int k, bool ties, uint32_t seed) {
    const size_t nsrc = (size_t) (ncols * nrows);
    const size_t nout = (size_t) (nrows * k);

    float *   src = sycl::malloc_shared<float>(nsrc, q);
    int32_t * dst = sycl::malloc_shared<int32_t>(nout + 64, q);

    uint32_t state = seed;
    for (size_t i = 0; i < nsrc; i++) src[i] = next_value(state, ties);
    for (size_t i = 0; i < nout + 64; i++) dst[i] = -7;  // guard tail past the outputs must stay untouched

    ggml_sycl_top_k_radix(ctx, src, dst, ncols, nrows, k, &q);
    q.wait();

    int64_t bad_rows = 0, guard = 0;
    std::vector<uint8_t> seen((size_t) ncols);
    std::vector<int64_t> order((size_t) ncols);
    for (int64_t r = 0; r < nrows; r++) {
        const float * v = src + r * ncols;
        const int32_t * got = dst + r * k;

        // the k-th largest value, and how many columns are strictly above it
        for (int64_t i = 0; i < ncols; i++) order[(size_t) i] = i;
        std::partial_sort(order.begin(), order.begin() + k, order.end(), [&](int64_t a, int64_t b) {
            return v[a] > v[b] || (v[a] == v[b] && a < b);
        });
        const float kth = v[order[(size_t) k - 1]];
        int64_t n_gt = 0;
        for (int64_t i = 0; i < ncols; i++) n_gt += v[i] > kth;

        std::fill(seen.begin(), seen.end(), (uint8_t) 0);
        bool ok = true;
        int64_t got_gt = 0;
        for (int j = 0; j < k; j++) {
            const int64_t g = got[j];
            if (g < 0 || g >= ncols) { ok = false; continue; }
            if (seen[(size_t) g]) { ok = false; continue; }
            seen[(size_t) g] = 1;
            if (!(v[g] >= kth)) ok = false;   // NaN fails too
            got_gt += v[g] > kth;
        }
        if (got_gt != n_gt) ok = false;
        bad_rows += !ok;
    }
    for (size_t i = nout; i < nout + 64; i++) guard += dst[i] != -7;

    const bool ok = bad_rows == 0 && guard == 0;
    printf("TOP_K F32 %lldx%lld k=%d %s: mismatches: %lld of %lld, guard writes: %lld of 64: %s\n",
           (long long) ncols, (long long) nrows, k, ties ? "ties" : "distinct",
           (long long) bad_rows, (long long) nrows, (long long) guard, ok ? "ok" : "FAIL");

    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    int failed = 0, total = 0;
    failed += check(q, ctx, 1000, 3, 16, false, 12345u) != 0;  total++;
    failed += check(q, ctx, 70000, 2, 32, true, 54321u) != 0;  total++;
    printf("checks: %d, failed: %d\n", total, failed);
    return failed != 0;
}

// Exit 70 when the runtime reports no device (top_k/run.sh skips that backend).
int main() {
    try {
        sycl::queue q{sycl::gpu_selector_v};
        return run_all(q);
    } catch (const sycl::exception & e) {
        printf("no device: %s\n", e.what());
        return 70;
    }
}
