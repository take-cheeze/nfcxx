// The real ggml-sycl rope.cpp (ggml/src/ggml-sycl/rope.cpp, unchanged), compiled as this program's own TU through the nfcxx
// SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first). The entry
// point is the real ggml_sycl_rope, called with a ggml_backend_sycl_context and a ggml_tensor dst whose src[0] is the input
// (F32 or F16), src[1] the int32 positions (one per token, ne2 of them) and src[2] nullptr. The ggml helpers and the
// backend's ggml_sycl_info() come from libggml-sycl.so.
//
// Norm mode only (mode 0, not NEOX, not mrope, not vision), dst type equal to src type, no freq_factors, ext_factor 0 (no
// YaRN ramp), attn_factor 1, freq_base 10000, freq_scale 0.5. Each shape is run with the full head dimension rotated and with
// the first half rotated (the rest copied). The oracle is the ggml definition of the norm rotation, in double precision: for
// the pair (2k, 2k+1) of row (i1, i2, i3), theta = freq_scale * pos[i2] * freq_base^(-2k/n_dims), out0 = x0 cos - x1 sin,
// out1 = x0 sin + x1 cos; unrotated columns are copied. Every element is checked: 1e-4 relative for F32, 2e-3 relative for
// F16 (the output is rounded to half). 64 guard slots past the output must stay untouched.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/soft_max/soft_max_real.cpp.
#include "rope.cpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <type_traits>
#include <vector>

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float rp_next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

// One check of T (float or sycl::half) on shape ne (ne0 is the head dimension, ne1 the heads, ne2 the tokens), with n_dims
// rotated columns (the first n_dims of each row).
template <typename T>
static int rope_check(sycl::queue & q, ggml_backend_sycl_context & ctx, const int64_t ne[4], int64_t n_dims, uint32_t seed,
                      const char * shape_name, const char * rot_name) {
    const int64_t ne0 = ne[0], ne1 = ne[1], ne2 = ne[2], ne3 = ne[3];
    const int64_t nrows = ne1 * ne2 * ne3;
    const int64_t n     = ne0 * nrows;
    const float   freq_base = 10000.0f, freq_scale = 0.5f, ext_factor = 0.0f, attn_factor = 1.0f;
    const float   beta_fast = 32.0f, beta_slow = 1.0f;
    const enum ggml_type gt = std::is_same_v<T, float> ? GGML_TYPE_F32 : GGML_TYPE_F16;

    T *       src = sycl::malloc_shared<T>(n, q);
    T *       dst = sycl::malloc_shared<T>(n + 64, q);
    int32_t * pos = sycl::malloc_shared<int32_t>(ne2, q);
    uint32_t state = seed;
    for (int64_t i = 0; i < n; i++) src[i] = T(rp_next_value(state));
    for (int64_t t = 0; t < ne2; t++) pos[t] = (int32_t) (3 * t + 5);
    const T guard = T(-7.0f);
    for (int64_t i = 0; i < n + 64; i++) dst[i] = guard;  // guard tail past n must stay untouched

    ggml_tensor src_t{};
    src_t.type = gt;
    for (int d = 0; d < 4; d++) src_t.ne[d] = ne[d];
    src_t.nb[0] = sizeof(T);
    src_t.nb[1] = src_t.nb[0] * ne0;
    src_t.nb[2] = src_t.nb[1] * ne1;
    src_t.nb[3] = src_t.nb[2] * ne2;
    src_t.data = src;

    ggml_tensor pos_t{};
    pos_t.type = GGML_TYPE_I32;
    pos_t.ne[0] = ne2; pos_t.ne[1] = 1; pos_t.ne[2] = 1; pos_t.ne[3] = 1;
    pos_t.nb[0] = sizeof(int32_t);
    pos_t.nb[1] = pos_t.nb[0] * ne2;
    pos_t.nb[2] = pos_t.nb[1];
    pos_t.nb[3] = pos_t.nb[2];
    pos_t.data = pos;

    ggml_tensor dst_t{};
    dst_t.type = gt;
    for (int d = 0; d < 4; d++) dst_t.ne[d] = ne[d];
    dst_t.nb[0] = sizeof(T);
    dst_t.nb[1] = dst_t.nb[0] * ne0;
    dst_t.nb[2] = dst_t.nb[1] * ne1;
    dst_t.nb[3] = dst_t.nb[2] * ne2;
    dst_t.data = dst;
    dst_t.src[0] = &src_t;
    dst_t.src[1] = &pos_t;
    dst_t.src[2] = nullptr;
    // op_params (int32 slots): [1] n_dims, [2] mode 0 (norm), [4] n_ctx_orig, [5] freq_base, [6] freq_scale, [7] ext_factor,
    // [8] attn_factor, [9] beta_fast, [10] beta_slow, [11..14] mrope sections (unused), [15] n_offs (0)
    int32_t * p = dst_t.op_params;
    p[1] = (int32_t) n_dims;
    p[2] = 0;
    p[4] = 2048;
    memcpy(&p[5], &freq_base, sizeof(float));
    memcpy(&p[6], &freq_scale, sizeof(float));
    memcpy(&p[7], &ext_factor, sizeof(float));
    memcpy(&p[8], &attn_factor, sizeof(float));
    memcpy(&p[9], &beta_fast, sizeof(float));
    memcpy(&p[10], &beta_slow, sizeof(float));
    p[15] = 0;

    ggml_sycl_rope(ctx, &dst_t);
    q.wait();

    // reference: per row r = (i1, i2, i3) of ne0 contiguous values; the position is pos[i2] (i2 = (r / ne1) % ne2)
    const double theta_scale = std::pow((double) freq_base, -2.0 / (double) n_dims);
    int64_t bad = 0, guard_w = 0;
    double  worst = 0.0;
    const double tol_rel = sizeof(T) == 2 ? 2e-3 : 1e-4;
    for (int64_t r = 0; r < nrows; r++) {
        const int64_t i2 = (r / ne1) % ne2;
        for (int64_t i0 = 0; i0 < ne0; i0++) {
            const int64_t p0 = i0 & ~(int64_t) 1;  // the pair's first column
            const double  x0 = (float) src[r * ne0 + p0];
            const double  x1 = (float) src[r * ne0 + p0 + 1];
            double want;
            if (i0 >= n_dims) {
                want = (float) src[r * ne0 + i0];
            } else {
                const double theta = freq_scale * (double) pos[i2] * std::pow(theta_scale, (double) (p0 / 2));
                const double c = std::cos(theta) * attn_factor;
                const double s = std::sin(theta) * attn_factor;
                want = (i0 == p0) ? x0 * c - x1 * s : x0 * s + x1 * c;
            }
            const double got = (float) dst[r * ne0 + i0];
            const double err = std::fabs(got - want);
            const double tol = tol_rel * std::max(1.0, std::fabs(want));
            if (!(err <= tol)) bad++;  // NaN fails too
            if (!std::isnan(err) && err > worst) worst = err;
        }
    }
    for (int64_t i = n; i < n + 64; i++) guard_w += (float) dst[i] != (float) guard;

    const bool ok = bad == 0 && guard_w == 0;
    printf("rope %s %s %s: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           sizeof(T) == 2 ? "F16" : "F32", shape_name, rot_name, (long long) bad, (long long) n, (long long) guard_w, worst,
           ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    sycl::free(pos, q);
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
        for (int rot = 0; rot < 2; rot++) {
            const int64_t n_dims  = rot ? shapes[s][0] / 2 : shapes[s][0];
            const char *  rotname = rot ? "partial" : "full";
            const uint32_t seed = 2024u + 17u * (uint32_t) s + 5u * (uint32_t) rot;
            failed += rope_check<float>(q, ctx, shapes[s], n_dims, seed, names[s], rotname) != 0;
            checks++;
            failed += rope_check<sycl::half>(q, ctx, shapes[s], n_dims, seed + 1u, names[s], rotname) != 0;
            checks++;
        }
    }
    printf("checks: %d, failed: %d\n", checks, failed);
    return failed != 0;
}
