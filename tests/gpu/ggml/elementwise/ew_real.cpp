// The real ggml-sycl element_wise.cpp (ggml/src/ggml-sycl/element_wise.cpp, unchanged), compiled as this program's own TU
// through the nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (ew_run.sh puts a mutant copy's dir
// first). The entry point is the real public ggml_sycl_<op> (EW_CALL), called with a ggml_backend_sycl_context and a
// ggml_tensor whose src[0] is the input; the ggml helpers and the backend's ggml_sycl_info() come from libggml-sycl.so.
//
// The driver (ew_run.sh) defines, per op: EW_ID (the op's index in ref() below), EW_CALL (the entry point), EW_OPNAME (the
// op's name, as a token), EW_LO and EW_HI (the input range [EW_LO, EW_HI)), EW_P0 and EW_P1 (the two float op_params the
// entry point reads; 0 for ops that take none), and EW_FLAT_ONLY (flat views only, for the contiguous-only launchers).
//
// The link must hide this TU's own definitions of the dpct helpers (ew_run.sh passes a version script that makes every
// symbol of the executable local), as in tests/gpu/ggml/fill_real/fill_real.cpp.
//
// Checks: F32 (src and dst), flat (contiguous) and strided (src row stride skips one element; dst contiguous), two shapes,
// 64 guard slots past the output, every element checked against the double-precision reference computed from the input as
// stored. Tolerance 1e-5 relative (absolute below 1).
#include "element_wise.cpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#define EW_STR2(x) #x
#define EW_STR(x) EW_STR2(x)
#define EW_NAME EW_STR(EW_OPNAME)

// The double-precision reference of the op EW_ID (the ids are ew_run.sh's table).
static double ref(double x) {
    switch (EW_ID) {
        case 0:  return std::sqrt(x);
        case 1:  return x * x;
        case 2:  return x < -1.5 ? -1.5 : (x > 2.0 ? 2.0 : x);  // clamp to [EW_P0, EW_P1] = [-1.5, 2.0]
        case 3:  return std::sin(x);
        case 4:  return std::cos(x);
        case 5:  return std::log(x);
        case 6:  return std::exp(x);
        case 7:  return std::expm1(x);
        case 8:  return std::tanh(x);
        case 9:  return 1.0 / (1.0 + std::exp(-x));
        case 10: return std::fabs(x);
        case 11: return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
        case 12: return x > 0.0 ? 1.0 : 0.0;
        case 13: return std::min(1.0, std::max(0.0, (x + 3.0) / 6.0));
        case 14: return x * std::min(1.0, std::max(0.0, (x + 3.0) / 6.0));
        case 15: return std::log1p(std::exp(x));
        case 16: return x > 0.0 ? x : 0.1 * x;  // leaky slope EW_P0 = 0.1
        case 17: return x > 0.0 ? x : std::expm1(x);
        case 18: return x / (1.0 + std::exp(-1.702 * x));
        case 19: return 0.5 * x * (1.0 + std::erf(x * 0.70710678118654752440));
        case 20: return std::floor(x);
        case 21: return std::ceil(x);
        case 22: return std::round(x);
        case 23: return std::trunc(x);
        default: return 0.0;
    }
}

// The input values: a fixed LCG over [EW_LO, EW_HI), so the run is repeatable.
static float next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    const float u = (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000;
    return (float) (EW_LO) + u * ((float) (EW_HI) - (float) (EW_LO));
}

// One check: the op over the ne shape, flat or strided.
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, const int64_t ne[4], bool strided, uint32_t seed) {
    using T = float;
    const int64_t n = ne[0] * ne[1] * ne[2] * ne[3];
    const int64_t pad = strided ? 1 : 0;
    const size_t  esz = sizeof(T);
    const size_t  nb1 = (size_t)(ne[0] + pad) * esz;
    const size_t  nb2 = nb1 * ne[1];
    const size_t  nb3 = nb2 * ne[2];
    const size_t  src_elems = (size_t)(nb3 * ne[3] / esz);
    const size_t  nbd1 = esz * ne[0];
    const size_t  nbd2 = nbd1 * ne[1];
    const size_t  nbd3 = nbd2 * ne[2];

    T * src = sycl::malloc_shared<T>(src_elems, q);
    T * dst = sycl::malloc_shared<T>(n + 64, q);
    uint32_t state = seed;
    for (size_t i = 0; i < src_elems; i++) src[i] = next_value(state);
    for (int64_t i = 0; i < n + 64; i++) dst[i] = -7.0f;  // guard tail past n must stay untouched

    // element index i (dst, row-major over ne) -> src element at the view's strides
    auto src_index = [&](int64_t i) -> size_t {
        const int64_t i0 = i % ne[0];
        const int64_t i1 = (i / ne[0]) % ne[1];
        const int64_t i2 = (i / (ne[0] * ne[1])) % ne[2];
        const int64_t i3 = i / (ne[0] * ne[1] * ne[2]);
        return (size_t)(i0 + i1 * (ne[0] + pad) + i2 * (ne[0] + pad) * ne[1] + i3 * (ne[0] + pad) * ne[1] * ne[2]);
    };

    ggml_tensor src_t{};
    src_t.type = GGML_TYPE_F32;
    for (int d = 0; d < 4; d++) src_t.ne[d] = ne[d];
    src_t.nb[0] = esz; src_t.nb[1] = nb1; src_t.nb[2] = nb2; src_t.nb[3] = nb3;
    src_t.data = src;

    ggml_tensor dst_t{};
    dst_t.type = GGML_TYPE_F32;
    for (int d = 0; d < 4; d++) dst_t.ne[d] = ne[d];
    dst_t.nb[0] = esz; dst_t.nb[1] = nbd1; dst_t.nb[2] = nbd2; dst_t.nb[3] = nbd3;
    dst_t.data = dst;
    dst_t.src[0] = &src_t;
    {
        const float p0 = (float) (EW_P0), p1 = (float) (EW_P1);
        std::memcpy(dst_t.op_params, &p0, sizeof(float));
        std::memcpy((float *) dst_t.op_params + 1, &p1, sizeof(float));
    }

    EW_CALL(ctx, &dst_t);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const double x    = (double) src[strided ? src_index(i) : i];
        const double want = ref(x);
        const double got  = (double) dst[i];
        const double err  = std::fabs(got - want);
        const double tol  = 1e-5 * std::max(1.0, std::fabs(want));
        if (!(err <= tol)) bad++;  // NaN fails too
        if (!std::isnan(err) && err > worst) worst = err;
    }
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("%s F32 %lldx%lldx%lldx%lld %s: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           EW_NAME, (long long)ne[0], (long long)ne[1], (long long)ne[2], (long long)ne[3],
           strided ? "strided" : "flat", (long long)bad, (long long)n, (long long)guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t shapes[2][4] = { { 128, 2, 2, 2 }, { 5, 7, 11, 13 } };
    // ops whose upstream launcher is the contiguous-only dispatch (dispatch_ggml_sycl_op_unary) index the source flat, so
    // they are checked on flat views only (EW_FLAT_ONLY, set by ew_run.sh)
#ifdef EW_FLAT_ONLY
    const int nstrided = 1;
#else
    const int nstrided = 2;
#endif
    int failed = 0, total = 0;
    for (int s = 0; s < 2; s++) {
        for (int strided = 0; strided < nstrided; strided++) {
            failed += check(q, ctx, shapes[s], strided != 0, 12345u + 31u * s + strided);
            total++;
        }
    }
    printf("checks: %d, failed: %d\n", total, failed);
    return failed != 0;
}

// Exit 70 when the runtime reports no device (ew_run.sh skips that backend).
int main() {
    try {
        sycl::queue q{sycl::gpu_selector_v};
        return run_all(q);
    } catch (const sycl::exception & e) {
        printf("no device: %s\n", e.what());
        return 70;
    }
}
