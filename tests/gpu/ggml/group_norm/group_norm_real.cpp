// The real ggml-sycl norm.cpp (ggml/src/ggml-sycl/norm.cpp, unchanged), compiled as this program's own TU through the nfcxx
// SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first). The op is
// ggml_sycl_op_group_norm (GGML_OP_GROUP_NORM): num_groups = op_params[0], eps = op_params[1] (F32). group_norm_f32_sycl
// launches one work-group per group; the group_size < 1024 branch uses one sub-group of WARP_SIZE (16) work-items, the
// other branch the work-group size with an s_sum local accessor. The ggml helpers and the backend's ggml_sycl_info() come
// from libggml-sycl.so. A version script keeps every symbol of this executable local (see diag_real.cpp).
//
// A group is the contiguous run of group_size = ne0 * ne1 * ceil(ne2 / groups) elements the kernel uses (ne3 must be 1).
// Each check compares every output element with a double-precision reference (two-pass mean and variance, y = (x - mean) /
// sqrt(var + eps)) at 1e-5 relative tolerance (1e-5 absolute below 1), and 64 guard slots past the output must stay put.
// The groups have mixed magnitude (group 0 and 1 amplitude 4, group 2 amplitude 1e-3 where eps matters, group 3 all zeros).
// argv: none (the two shapes of the test) or ne0 ne1 ne2 ne3 groups for one shape.
#include "norm.cpp"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <cstdint>
#include <optional>

static const float EPS = 1e-6f;

static uint32_t lcg(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return state;
}

static float next_value(uint32_t & state, double amp) {
    const float u = (float) ((lcg(state) >> 8) & 0xFFFFFF) / (float) 0x1000000;  // [0, 1)
    return (float) ((2.0 * u - 1.0) * amp);
}

// The amplitude of group g (of the flattened ne0 * ne1 * ne2 elements): 4, 4, 1e-3 and 0, repeating.
static double group_amp(int64_t g) {
    if (g % 4 == 3) return 0.0;
    if (g % 4 == 2) return 1e-3;
    return 4.0;
}

// One check: ggml_sycl_op_group_norm over an ne shape and a group count. Prints one verdict line; returns 0 when it passes.
static int check(ggml_backend_sycl_context & ctx, sycl::queue & q, const int64_t ne[4], int groups, uint32_t seed) {
    const int64_t ne_elements = ne[0] * ne[1] * ne[2];       // the kernel reads ne3 == 1 only
    const int64_t n = ne_elements * ne[3];
    const int64_t group_size = ne[0] * ne[1] * ((ne[2] + groups - 1) / groups);

    float * src = sycl::malloc_shared<float>(n, q);
    float * dst = sycl::malloc_shared<float>(n + 64, q);
    uint32_t state = seed;
    for (int64_t i = 0; i < n; i++) {
        const double amp = group_amp(i / group_size);
        src[i] = next_value(state, amp);
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
    const int32_t ngroups = groups;
    memcpy(&t.op_params[0], &ngroups, sizeof(int32_t));
    memcpy(&t.op_params[1], &EPS, sizeof(float));

    ggml_sycl_op_group_norm(ctx, &t);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t g = 0; g * group_size < ne_elements; g++) {
        const int64_t lo = g * group_size;
        const int64_t hi = std::min(lo + group_size, ne_elements);
        double sum = 0.0;
        for (int64_t i = lo; i < hi; i++) sum += (double) src[i];
        const double mean = sum / (double) group_size;
        double sq = 0.0;
        for (int64_t i = lo; i < hi; i++) {
            const double d = (double) src[i] - mean;
            sq += d * d;
        }
        const double inv_std = 1.0 / std::sqrt(sq / (double) group_size + (double) EPS);
        for (int64_t i = lo; i < hi; i++) {
            const double want = ((double) src[i] - mean) * inv_std;
            const double got  = (double) dst[i];
            const double err  = std::fabs(got - want);
            const double tol  = 1e-5 * std::max(1.0, std::fabs(want));
            if (!(err <= tol)) bad++;  // NaN fails too
            if (!std::isnan(err) && err > worst) worst = err;
        }
    }
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("group_norm %lldx%lldx%lldx%lld groups %d: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           (long long) ne[0], (long long) ne[1], (long long) ne[2], (long long) ne[3], groups,
           (long long) bad, (long long) n, (long long) guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

// Exit 70 when the runtime reports no device (run.sh skips that backend).
int main(int argc, char ** argv) {
    int64_t shapes[2][4] = { { 16, 8, 8, 1 }, { 64, 16, 8, 1 } };
    int groups = 4;
    int n_shapes = 2;
    if (argc == 6) {
        for (int i = 0; i < 4; i++) shapes[0][i] = atoll(argv[1 + i]);
        groups = atoi(argv[5]);
        n_shapes = 1;
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [ne0 ne1 ne2 ne3 groups]\n", argv[0]);
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
    for (int s = 0; s < n_shapes; s++) failed += check(ctx, *q, shapes[s], groups, 6161u + 17u * s);
    printf("checks: %d, failed: %d\n", n_shapes, failed);
    return failed != 0;
}
