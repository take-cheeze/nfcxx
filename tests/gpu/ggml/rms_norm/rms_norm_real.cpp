// The real ggml-sycl norm.cpp (ggml/src/ggml-sycl/norm.cpp, unchanged), compiled as this program's own TU through the nfcxx
// SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first). The op is
// ggml_sycl_op_rms_norm, which launches rms_norm_f32_sycl's ncols < 1024 branch: one sub-group of WARP_SIZE (16) work-items
// reduces each row through dpct::permute_sub_group_by_xor (select_from_group), so the reduction needs real 16-lane
// sub-groups. The ggml helpers and the backend's ggml_sycl_info() / get_current_device_id() / g_ggml_sycl_debug come from
// libggml-sycl.so. A version script keeps every symbol of this executable local, so the TU's copies of the ggml-sycl
// functions do not interpose libggml-sycl's (see diag_real.cpp).
//
// Each check is one shape {ne0, ne1, ne2, ne3} (ne0 is the reduced dimension, contiguous rows): every output element is
// compared with a double-precision reference (tolerance 1e-5 relative, 1e-5 absolute below 1), and 64 guard slots past the
// output must stay put. Rows have mixed magnitude (so eps matters: a row of zeros and a row of 1e-3 values).
// argv: none (the two shapes of the test) or ne0 ne1 ne2 ne3 for one shape.
#include "norm.cpp"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <cstdint>
#include <optional>

static const float EPS = 1e-6f;

// The input values: a fixed LCG, so the run is repeatable. Row r has amplitude amp(r): mostly 4, every fifth row 1e-3 (mean
// square ~3e-7, where eps is a third of the denominator), and every seventh row all zeros (eps alone keeps the division
// finite; without it 0/0 is NaN).
static uint32_t lcg(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return state;
}

static float next_value(uint32_t & state, double amp) {
    const float u = (float) ((lcg(state) >> 8) & 0xFFFFFF) / (float) 0x1000000;  // [0, 1)
    return (float) ((2.0 * u - 1.0) * amp);
}

static double row_amp(int64_t row) {
    if (row % 7 == 3) return 0.0;
    if (row % 5 == 2) return 1e-3;
    return 4.0;
}

// One check: ggml_sycl_op_rms_norm over an ne shape. Prints one verdict line; returns 0 when it passes.
static int check(ggml_backend_sycl_context & ctx, sycl::queue & q, const int64_t ne[4], uint32_t seed) {
    const int64_t n = ne[0] * ne[1] * ne[2] * ne[3];
    const int64_t nrows = ne[1] * ne[2] * ne[3];

    float * src = sycl::malloc_shared<float>(n, q);
    float * dst = sycl::malloc_shared<float>(n + 64, q);
    uint32_t state = seed;
    for (int64_t r = 0; r < nrows; r++) {
        const double amp = row_amp(r);
        for (int64_t c = 0; c < ne[0]; c++) src[r * ne[0] + c] = next_value(state, amp);
    }
    for (int64_t i = 0; i < n + 64; i++) dst[i] = -7.0f;  // guard tail past n must stay untouched

    ggml_tensor s{};
    s.type = GGML_TYPE_F32;
    s.ne[0] = ne[0]; s.ne[1] = ne[1]; s.ne[2] = ne[2]; s.ne[3] = ne[3];
    s.nb[0] = sizeof(float); s.nb[1] = s.nb[0] * s.ne[0]; s.nb[2] = s.nb[1] * s.ne[1]; s.nb[3] = s.nb[2] * s.ne[2];
    s.data = src;

    ggml_tensor t{};
    t.type = GGML_TYPE_F32;
    t.ne[0] = ne[0]; t.ne[1] = ne[1]; t.ne[2] = ne[2]; t.ne[3] = ne[3];
    t.nb[0] = sizeof(float); t.nb[1] = t.nb[0] * t.ne[0]; t.nb[2] = t.nb[1] * t.ne[1]; t.nb[3] = t.nb[2] * t.ne[2];
    t.data = dst;
    t.src[0] = &s;
    memcpy(t.op_params, &EPS, sizeof(float));

    ggml_sycl_op_rms_norm(ctx, &t);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t r = 0; r < nrows; r++) {
        double sum2 = 0.0;
        for (int64_t c = 0; c < ne[0]; c++) {
            const double x = (double) src[r * ne[0] + c];
            sum2 += x * x;
        }
        const double scale = 1.0 / std::sqrt(sum2 / (double) ne[0] + (double) EPS);
        for (int64_t c = 0; c < ne[0]; c++) {
            const int64_t i = r * ne[0] + c;
            const double want = (double) src[i] * scale;
            const double got  = (double) dst[i];
            const double err  = std::fabs(got - want);
            const double tol  = 1e-5 * std::max(1.0, std::fabs(want));
            if (!(err <= tol)) bad++;  // NaN fails too
            if (!std::isnan(err) && err > worst) worst = err;
        }
    }
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("rms_norm %lldx%lldx%lldx%lld: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           (long long) ne[0], (long long) ne[1], (long long) ne[2], (long long) ne[3],
           (long long) bad, (long long) n, (long long) guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

// Exit 70 when the runtime reports no device (run.sh skips that backend).
int main(int argc, char ** argv) {
    int64_t shapes[2][4] = { { 64, 4, 2, 1 }, { 128, 7, 3, 2 } };
    int n_shapes = 2;
    if (argc == 5) {
        for (int i = 0; i < 4; i++) shapes[0][i] = atoll(argv[1 + i]);
        n_shapes = 1;
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [ne0 ne1 ne2 ne3]\n", argv[0]);
        return 2;
    }
    std::optional<sycl::queue> q;
    try {
        q.emplace(sycl::gpu_selector_v);
    } catch (const sycl::exception & e) {
        printf("no device: %s\n", e.what());
        return 70;
    }
    printf("device: %s\n", q->get_device().get_info<sycl::info::device::name>().c_str());
    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &*q;
    int failed = 0;
    for (int s = 0; s < n_shapes; s++) failed += check(ctx, *q, shapes[s], 4242u + 17u * s);
    printf("checks: %d, failed: %d\n", n_shapes, failed);
    return failed != 0;
}
