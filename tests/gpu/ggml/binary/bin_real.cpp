// The real ggml-sycl binbcast.cpp (ggml/src/ggml-sycl/binbcast.cpp, unchanged), compiled as this program's own TU through
// the nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (bin_run.sh puts a mutant copy's dir
// first). The entry point is the real public ggml_sycl_<op> (BIN_CALL), called with a ggml_backend_sycl_context and a
// ggml_tensor whose src[0] and src[1] are the inputs; the ggml helpers and the backend's ggml_sycl_info() come from
// libggml-sycl.so.
//
// The driver (bin_run.sh) defines, per op: BIN_ID (the op's index in ref() below), BIN_CALL (the entry point), BIN_OPNAME
// (the op's name, as a token), BIN_LO0/BIN_HI0 (the src0 range [LO, HI)) and BIN_LO1/BIN_HI1 (the src1 range).
//
// The link must hide this TU's own definitions of the dpct helpers (bin_run.sh passes a version script that makes every
// symbol of the executable local), as in tests/gpu/ggml/elementwise/ew_real.cpp.
//
// Checks: F32 (src0, src1 and dst), contiguous views, two cases: same shape (src1 has dst's shape) and one broadcast
// (src1 is 1 in dims 0 and 2 and repeats over them, the ggml broadcast rule). 64 guard slots past the output, every element
// checked against the double-precision reference computed from the inputs as stored. Tolerance 1e-5 relative (absolute
// below 1).
#include "binbcast.cpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#define BIN_STR2(x) #x
#define BIN_STR(x) BIN_STR2(x)
#define BIN_NAME BIN_STR(BIN_OPNAME)

// The double-precision reference of the op BIN_ID (the ids are bin_run.sh's table).
static double ref(double a, double b) {
    switch (BIN_ID) {
        case 0: return a + b;
        case 1: return a - b;
        case 2: return a * b;
        case 3: return a / b;
        default: return 0.0;
    }
}

// The input values: a fixed LCG over [lo, hi), so the run is repeatable.
static float next_value(uint32_t & state, float lo, float hi) {
    state = state * 1664525u + 1013904223u;
    const float u = (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000;
    return lo + u * (hi - lo);
}

static int64_t prod4(const int64_t ne[4]) { return ne[0] * ne[1] * ne[2] * ne[3]; }

// One check: dst(ne0) = op(src0(ne0), src1(ne1)) with src1 broadcast over dst; all three contiguous F32.
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, const int64_t ne0[4], const int64_t ne1[4],
                 bool bcast, uint32_t seed) {
    using T = float;
    const int64_t n  = prod4(ne0);
    const int64_t n1 = prod4(ne1);
    const size_t  esz = sizeof(T);

    T * a = sycl::malloc_shared<T>(n, q);
    T * b = sycl::malloc_shared<T>(n1, q);
    T * dst = sycl::malloc_shared<T>(n + 64, q);
    uint32_t state = seed;
    for (int64_t i = 0; i < n; i++)  a[i] = next_value(state, (float) (BIN_LO0), (float) (BIN_HI0));
    for (int64_t i = 0; i < n1; i++) b[i] = next_value(state, (float) (BIN_LO1), (float) (BIN_HI1));
    for (int64_t i = 0; i < n + 64; i++) dst[i] = -7.0f;  // guard tail past n must stay untouched

    auto contiguous = [&](ggml_tensor & t, const int64_t ne[4], void * data) {
        t.type = GGML_TYPE_F32;
        for (int d = 0; d < 4; d++) t.ne[d] = ne[d];
        t.nb[0] = esz;
        t.nb[1] = t.nb[0] * ne[0];
        t.nb[2] = t.nb[1] * ne[1];
        t.nb[3] = t.nb[2] * ne[2];
        t.data = data;
    };

    ggml_tensor src0_t{}, src1_t{}, dst_t{};
    contiguous(src0_t, ne0, a);
    contiguous(src1_t, ne1, b);
    contiguous(dst_t, ne0, dst);
    dst_t.src[0] = &src0_t;
    dst_t.src[1] = &src1_t;

    BIN_CALL(ctx, &dst_t);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const int64_t i0 = i % ne0[0];
        const int64_t i1 = (i / ne0[0]) % ne0[1];
        const int64_t i2 = (i / (ne0[0] * ne0[1])) % ne0[2];
        const int64_t i3 = i / (ne0[0] * ne0[1] * ne0[2]);
        const int64_t j = (i0 % ne1[0]) + (i1 % ne1[1]) * ne1[0] + (i2 % ne1[2]) * ne1[0] * ne1[1]
                        + (i3 % ne1[3]) * ne1[0] * ne1[1] * ne1[2];
        const double want = ref((double) a[i], (double) b[j]);
        const double got  = (double) dst[i];
        const double err  = std::fabs(got - want);
        const double tol  = 1e-5 * std::max(1.0, std::fabs(want));
        if (!(err <= tol)) bad++;  // NaN fails too
        if (!std::isnan(err) && err > worst) worst = err;
    }
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("%s F32 %lldx%lldx%lldx%lld src1 %lldx%lldx%lldx%lld %s: mismatches: %lld of %lld, guard writes: %lld of 64, "
           "max abs err %.3g: %s\n",
           BIN_NAME, (long long)ne0[0], (long long)ne0[1], (long long)ne0[2], (long long)ne0[3],
           (long long)ne1[0], (long long)ne1[1], (long long)ne1[2], (long long)ne1[3], bcast ? "bcast" : "same",
           (long long)bad, (long long)n, (long long)guard, worst, ok ? "ok" : "FAIL");
    sycl::free(a, q);
    sycl::free(b, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t dst_shape[4]   = { 5, 7, 11, 13 };
    const int64_t same_shape[4]  = { 5, 7, 11, 13 };
    const int64_t bcast_shape[4] = { 1, 7, 1, 13 };  // dims 0 and 2 broadcast

    int failed = 0, total = 0;
    failed += check(q, ctx, dst_shape, same_shape, false, 12345u);  total++;
    failed += check(q, ctx, dst_shape, bcast_shape, true, 54321u);  total++;
    printf("checks: %d, failed: %d\n", total, failed);
    return failed != 0;
}

// Exit 70 when the runtime reports no device (bin_run.sh skips that backend).
int main() {
    try {
        sycl::queue q{sycl::gpu_selector_v};
        return run_all(q);
    } catch (const sycl::exception & e) {
        printf("no device: %s\n", e.what());
        return 70;
    }
}
