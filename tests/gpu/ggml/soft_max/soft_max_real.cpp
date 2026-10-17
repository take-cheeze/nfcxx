// The real ggml-sycl softmax.cpp (ggml/src/ggml-sycl/softmax.cpp, unchanged), compiled as this program's own TU through the
// nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first).
// The entry point is the real ggml_sycl_op_soft_max, called with a ggml_backend_sycl_context and a ggml_tensor dst whose
// src[0] is the input and, for the masked variant, src[1] is the F32 mask; the ggml helpers and the backend's
// ggml_sycl_info() / get_current_device_id() come from libggml-sycl.so.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/fill_real/fill_real.cpp.
//
// Shapes 64x4x2x1 and 128x7x3x2 (ne0 is the softmax dimension, scale 1.0), without a mask and with an F32 mask of shape
// (ne0, ne1, ne2, 1), broadcast over ne3 by the real kernel's i13 = i03 % ne13. Every element is checked against a
// double-precision softmax of the scaled, masked row with a 1e-5 relative tolerance, and 64 guard slots past the output
// must stay untouched.
#include "softmax.cpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float sm_next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

// One check: soft_max over ne (ne0 is the softmax dimension), with or without the F32 mask of shape (ne0, ne1, ne2, 1).
static int sm_check(sycl::queue & q, ggml_backend_sycl_context & ctx, const int64_t ne[4], bool masked, uint32_t seed,
                    const char * shape_name) {
    const int64_t nrows = ne[1] * ne[2] * ne[3];
    const int64_t n     = ne[0] * nrows;
    const float   scale = 1.0f;

    float * src  = sycl::malloc_shared<float>(n, q);
    float * dst  = sycl::malloc_shared<float>(n + 64, q);
    float * mask = masked ? sycl::malloc_shared<float>(ne[0] * ne[1] * ne[2], q) : nullptr;
    uint32_t state = seed;
    for (int64_t i = 0; i < n; i++) src[i] = sm_next_value(state);
    if (mask) for (int64_t i = 0; i < ne[0] * ne[1] * ne[2]; i++) mask[i] = sm_next_value(state);
    for (int64_t i = 0; i < n + 64; i++) dst[i] = -7.0f;  // guard tail past n must stay untouched

    ggml_tensor src_t{};
    src_t.type = GGML_TYPE_F32;
    for (int d = 0; d < 4; d++) src_t.ne[d] = ne[d];
    src_t.nb[0] = sizeof(float);
    src_t.nb[1] = src_t.nb[0] * ne[0];
    src_t.nb[2] = src_t.nb[1] * ne[1];
    src_t.nb[3] = src_t.nb[2] * ne[2];
    src_t.data = src;

    // the mask: row (ne0 floats), slice (ne1 rows), and the broadcast over ne3 (ne13 = 1, stride 0 there)
    ggml_tensor mask_t{};
    mask_t.type = GGML_TYPE_F32;
    mask_t.ne[0] = ne[0]; mask_t.ne[1] = ne[1]; mask_t.ne[2] = ne[2]; mask_t.ne[3] = 1;
    mask_t.nb[0] = sizeof(float);
    mask_t.nb[1] = mask_t.nb[0] * ne[0];
    mask_t.nb[2] = mask_t.nb[1] * ne[1];
    mask_t.nb[3] = mask_t.nb[2] * ne[2];
    mask_t.data = mask;

    ggml_tensor dst_t{};
    dst_t.type = GGML_TYPE_F32;
    for (int d = 0; d < 4; d++) dst_t.ne[d] = ne[d];
    dst_t.nb[0] = sizeof(float);
    dst_t.nb[1] = dst_t.nb[0] * ne[0];
    dst_t.nb[2] = dst_t.nb[1] * ne[1];
    dst_t.nb[3] = dst_t.nb[2] * ne[2];
    dst_t.data = dst;
    dst_t.src[0] = &src_t;
    dst_t.src[1] = masked ? &mask_t : nullptr;
    dst_t.src[2] = nullptr;
    memcpy(dst_t.op_params, &scale, sizeof(float));  // op_params[0] = scale; op_params[1] = max_bias = 0

    ggml_sycl_op_soft_max(ctx, &dst_t);
    q.wait();

    // reference: for row r = (i1, i2, i3), the scaled values plus the mask row (i1, i2) (the mask is broadcast over i3)
    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t r = 0; r < nrows; r++) {
        const int64_t i1 = r % ne[1];
        const int64_t i2 = (r / ne[1]) % ne[2];
        double mx = -INFINITY;
        std::vector<double> v(ne[0]);
        for (int64_t c = 0; c < ne[0]; c++) {
            const double m = mask ? (double) mask[i1 * ne[0] + i2 * ne[0] * ne[1] + c] : 0.0;
            v[c] = (double) src[r * ne[0] + c] * (double) scale + m;
            mx = std::max(mx, v[c]);
        }
        double sum = 0.0;
        for (int64_t c = 0; c < ne[0]; c++) { v[c] = std::exp(v[c] - mx); sum += v[c]; }
        for (int64_t c = 0; c < ne[0]; c++) {
            const double want = v[c] / sum;
            const double got  = (double) dst[r * ne[0] + c];
            const double err  = std::fabs(got - want);
            const double tol  = 1e-5 * std::max(1.0, std::fabs(want));
            if (!(err <= tol)) bad++;  // NaN fails too
            if (!std::isnan(err) && err > worst) worst = err;
        }
    }
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("soft_max F32 %s %s: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           shape_name, masked ? "mask" : "no-mask", (long long)bad, (long long)n, (long long)guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    if (mask) sycl::free(mask, q);
    return ok ? 0 : 1;
}

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t shapes[2][4] = { { 64, 4, 2, 1 }, { 128, 7, 3, 2 } };
    const char *  names[2]     = { "64x4x2x1", "128x7x3x2" };
    int failed = 0, checks = 0;
    for (int s = 0; s < 2; s++) {
        for (int masked = 0; masked < 2; masked++) {
            failed += sm_check(q, ctx, shapes[s], masked != 0, 2024u + 17u * s + 5u * masked, names[s]);
            checks++;
        }
    }
    printf("checks: %d, failed: %d\n", checks, failed);
    return failed != 0;
}
