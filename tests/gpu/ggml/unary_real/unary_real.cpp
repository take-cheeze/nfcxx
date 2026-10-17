// The real ggml-sycl element_wise.cpp (ggml/src/ggml-sycl/element_wise.cpp, unchanged), compiled as this program's own TU
// through the nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir
// first). The entry points are the real ggml_sycl_op_neg / _relu / _silu / _gelu, called with a ggml_backend_sycl_context and
// a ggml_tensor whose src[0] is the input; the ggml helpers and the backend's ggml_sycl_info() come from libggml-sycl.so.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/fill_real/fill_real.cpp.
//
// The checks are those of tests/gpu/ggml/unary/unary_kernel.cpp, for each type of the ops' three arms: F32, F16 and BF16
// (src and dst of one type), four ops, flat (contiguous src and dst) and strided (src row stride skips one element; dst
// contiguous), two shapes, 64 guard slots past the output, every element checked against a double-precision reference
// computed from the input as stored (already rounded to the type). The tolerance is 1e-5 relative for F32 and 1e-2
// relative for F16 and BF16 (absolute below 1), the precision of the type.
#include "element_wise.cpp"
#include <cmath>
#include <cstdio>
#include <cstring>

static double ref_op(int op, double x) {
    switch (op) {
        case 0: return -x;
        case 1: return x > 0.0 ? x : 0.0;
        case 2: return x / (1.0 + std::exp(-x));
        default: {
            const double c = std::sqrt(2.0 / 3.14159265358979323846);
            return 0.5 * x * (1.0 + std::tanh(c * (x + 0.044715 * x * x * x)));
        }
    }
}

static const char * op_name(int op) {
    switch (op) {
        case 0: return "neg";
        case 1: return "relu";
        case 2: return "silu";
        default: return "gelu";
    }
}

// The element type under test: its ggml type, its relative tolerance, and its name in the output.
template <typename T> struct elem;
template <> struct elem<float> {
    static constexpr ggml_type gtype = GGML_TYPE_F32;
    static constexpr double tol = 1e-5;
    static constexpr const char * name = "F32";
};
template <> struct elem<sycl::half> {
    static constexpr ggml_type gtype = GGML_TYPE_F16;
    static constexpr double tol = 1e-2;
    static constexpr const char * name = "F16";
};
template <> struct elem<sycl::ext::oneapi::bfloat16> {
    static constexpr ggml_type gtype = GGML_TYPE_BF16;
    static constexpr double tol = 1e-2;
    static constexpr const char * name = "BF16";
};

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

// Runs the real entry point for op on dst (whose src[0] is set).
static void run_op(ggml_backend_sycl_context & ctx, int op, ggml_tensor * dst) {
    switch (op) {
        case 0: ggml_sycl_op_neg(ctx, dst);  break;
        case 1: ggml_sycl_op_relu(ctx, dst); break;
        case 2: ggml_sycl_op_silu(ctx, dst); break;
        default: ggml_sycl_op_gelu(ctx, dst); break;
    }
}

// One check: op over the ne shape, flat or strided, with elements of type T.
template <typename T>
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, int op, const int64_t ne[4], bool strided, uint32_t seed) {
    const int64_t n = ne[0] * ne[1] * ne[2] * ne[3];
    const int64_t pad = strided ? 1 : 0;
    const size_t  esz = sizeof(T);
    const size_t  nb0 = esz;
    const size_t  nb1 = (size_t)(ne[0] + pad) * esz;
    const size_t  nb2 = nb1 * ne[1];
    const size_t  nb3 = nb2 * ne[2];
    const size_t  src_elems = (size_t)(nb3 * ne[3] / esz);
    const size_t  nbd0 = esz;
    const size_t  nbd1 = nbd0 * ne[0];
    const size_t  nbd2 = nbd1 * ne[1];
    const size_t  nbd3 = nbd2 * ne[2];

    T * src = sycl::malloc_shared<T>(src_elems, q);
    T * dst = sycl::malloc_shared<T>(n + 64, q);
    uint32_t state = seed;
    for (size_t i = 0; i < src_elems; i++) src[i] = static_cast<T>(next_value(state));
    for (int64_t i = 0; i < n + 64; i++) dst[i] = static_cast<T>(-7.0f);  // guard tail past n must stay untouched

    // element index i (dst, row-major over ne) -> src element at the view's strides
    auto src_index = [&](int64_t i) -> size_t {
        const int64_t i0 = i % ne[0];
        const int64_t i1 = (i / ne[0]) % ne[1];
        const int64_t i2 = (i / (ne[0] * ne[1])) % ne[2];
        const int64_t i3 = i / (ne[0] * ne[1] * ne[2]);
        return (size_t)(i0 + i1 * (ne[0] + pad) + i2 * (ne[0] + pad) * ne[1] + i3 * (ne[0] + pad) * ne[1] * ne[2]);
    };

    ggml_tensor src_t{};
    src_t.type = elem<T>::gtype;
    for (int d = 0; d < 4; d++) src_t.ne[d] = ne[d];
    src_t.nb[0] = nb0; src_t.nb[1] = nb1; src_t.nb[2] = nb2; src_t.nb[3] = nb3;
    src_t.data = src;

    ggml_tensor dst_t{};
    dst_t.type = elem<T>::gtype;
    for (int d = 0; d < 4; d++) dst_t.ne[d] = ne[d];
    dst_t.nb[0] = nbd0; dst_t.nb[1] = nbd1; dst_t.nb[2] = nbd2; dst_t.nb[3] = nbd3;
    dst_t.data = dst;
    dst_t.src[0] = &src_t;

    run_op(ctx, op, &dst_t);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const double x    = (double) (float) src[strided ? src_index(i) : i];
        const double want = ref_op(op, x);
        const double got  = (double) (float) dst[i];
        const double err  = std::fabs(got - want);
        const double tol  = elem<T>::tol * std::max(1.0, std::fabs(want));
        if (!(err <= tol)) bad++;  // NaN fails too
        if (!std::isnan(err) && err > worst) worst = err;
    }
    for (int64_t i = n; i < n + 64; i++) guard += (float) dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("%s %s %lldx%lldx%lldx%lld %s: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           op_name(op), elem<T>::name, (long long)ne[0], (long long)ne[1], (long long)ne[2], (long long)ne[3],
           strided ? "strided" : "flat", (long long)bad, (long long)n, (long long)guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

template <typename T>
static int run_type(sycl::queue & q, ggml_backend_sycl_context & ctx, int & total) {
    const int64_t shapes[2][4] = { { 128, 2, 2, 2 }, { 5, 7, 11, 13 } };
    int failed = 0;
    for (int op = 0; op < 4; op++) {
        for (int s = 0; s < 2; s++) {
            for (int strided = 0; strided < 2; strided++) {
                failed += check<T>(q, ctx, op, shapes[s], strided != 0, 12345u + 7u * op + 31u * s + strided);
                total++;
            }
        }
    }
    return failed;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    int failed = 0, total = 0;
    failed += run_type<float>(q, ctx, total);
    failed += run_type<sycl::half>(q, ctx, total);
    failed += run_type<sycl::ext::oneapi::bfloat16>(q, ctx, total);
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
