// The ggml-sycl SUM_ROWS op (ggml_sycl_op_sum_rows, ggml/src/ggml-sycl/ggml-sycl.cpp), compiled as this program's own TU through
// the nfcxx SYCL flow. The upstream definitions are static or inline inside ggml-sycl.cpp (too large to compile as a TU), so
// sum_rows_upstream.cpp holds their text copied verbatim (run.sh checks that), and this harness includes it as
// <sum_rows_upstream.cpp> through -I: the test dir for the real run, a sed copy of it (the mutant) for the mutant run. The
// launch and the kernel are the upstream ones; the ggml helpers, the backend's ggml_sycl_info() and ggml_sycl_set_device()
// come from libggml-sycl.so. Same link discipline as ew_real.cpp: a version script keeps every symbol of this executable local.
//
// Checks: F32 flat (contiguous, as the upstream kernel indexes x[row * ncols + i]), three shapes (the last has ncols > the
// warp size, so each lane strides), each row's sum against the double-precision reference, 64 guard slots past the output.
// Inputs are in [-1, 1) so the float sums stay well inside the tolerance (1e-5 relative, absolute below 1).
#include "common.hpp"
#include "ggml-sycl/presets.hpp"
#include <sum_rows_upstream.cpp>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

// The input values: a fixed LCG over [-1, 1), so the run is repeatable.
static float next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    const float u = (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000;
    return -1.0f + 2.0f * u;
}

// One check: ggml_sycl_op_sum_rows over a contiguous F32 tensor of shape ne; the output is {1, ne1, ne2, ne3}.
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, const int64_t ne[4], uint32_t seed) {
    const int64_t ncols = ne[0];
    const int64_t nrows = ne[1] * ne[2] * ne[3];
    const int64_t n = ncols * nrows;
    const size_t  esz = sizeof(float);

    float * src = sycl::malloc_shared<float>(n, q);
    float * dst = sycl::malloc_shared<float>(nrows + 64, q);
    uint32_t state = seed;
    for (int64_t i = 0; i < n; i++) src[i] = next_value(state);
    for (int64_t i = 0; i < nrows + 64; i++) dst[i] = -7.0f;  // guard tail past nrows must stay untouched

    ggml_tensor src_t{};
    src_t.type = GGML_TYPE_F32;
    for (int d = 0; d < 4; d++) src_t.ne[d] = ne[d];
    src_t.nb[0] = esz; src_t.nb[1] = esz * ne[0]; src_t.nb[2] = src_t.nb[1] * ne[1]; src_t.nb[3] = src_t.nb[2] * ne[2];
    src_t.data = src;

    ggml_tensor dst_t{};
    dst_t.type = GGML_TYPE_F32;
    dst_t.ne[0] = 1; dst_t.ne[1] = ne[1]; dst_t.ne[2] = ne[2]; dst_t.ne[3] = ne[3];
    dst_t.nb[0] = esz; dst_t.nb[1] = esz; dst_t.nb[2] = esz * ne[1]; dst_t.nb[3] = dst_t.nb[2] * ne[2];
    dst_t.data = dst;
    dst_t.src[0] = &src_t;

    ggml_sycl_op_sum_rows(ctx, &dst_t);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t r = 0; r < nrows; r++) {
        double want = 0.0;
        for (int64_t i = 0; i < ncols; i++) want += (double) src[r * ncols + i];
        const double got = (double) dst[r];
        const double err = std::fabs(got - want);
        const double tol = 1e-5 * std::max(1.0, std::fabs(want));
        if (!(err <= tol)) bad++;  // NaN fails too
        if (!std::isnan(err) && err > worst) worst = err;
    }
    for (int64_t i = nrows; i < nrows + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("sum_rows F32 %lldx%lldx%lldx%lld flat: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           (long long) ne[0], (long long) ne[1], (long long) ne[2], (long long) ne[3],
           (long long) bad, (long long) nrows, (long long) guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t shapes[3][4] = { { 128, 2, 2, 2 }, { 5, 7, 11, 13 }, { 300, 3, 1, 1 } };
    int failed = 0, total = 0;
    for (int s = 0; s < 3; s++) {
        failed += check(q, ctx, shapes[s], 777u + 31u * s);
        total++;
    }
    printf("checks: %d, failed: %d\n", total, failed);
    return failed != 0;
}

// Exit 70 when the runtime reports no device (run.sh skips that backend).
int main() {
    try {
        sycl::queue q{sycl::gpu_selector_v};
        return run_all(q);
    } catch (const sycl::exception & e) {
        printf("no device: %s\n", e.what());
        return 70;
    }
}
