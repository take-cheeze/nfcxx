// The F32 unary element-wise ops of ggml-sycl (ggml/src/ggml-sycl/element_wise.cpp): neg, relu, silu and gelu, each over
// the flat (contiguous) path and the strided path. The op kernels (op_tanh, op_exp, op_silu, op_gelu, op_relu, op_neg),
// unary_op_flat_kernel, unary_op_generic_kernel and the nd_range launch in ggml_sycl_op_unary are copied verbatim from
// element_wise.hpp, element_wise.cpp and the fastdiv helpers of common.hpp (fastdiv, init_fastdiv_values,
// fast_div_modulo). Replaced: the backend context and dispatch_ggml_sycl_op_unary (the launch takes a sycl::queue and
// the tensor strides as plain values), the GGML_ASSERT in init_fastdiv_values (an abort), ceil_div (the same formula),
// and WARP_SIZE (16, the Intel build default of ggml-sycl's CMakeLists.txt). Three deviations are needed by the nfcxx
// front end, not by the math: the bfloat16 branches are dropped (F32 only), the op lambdas are named functors, and the
// kernels take F by const reference (a by-value empty functor passed into a nested call is lowered to a static object the
// front end refuses). fastdiv's mul_hi is the plain 64-bit product (see mulhi32). The host side is a main in the style of
// fill_kernel.cpp: USM, a double-precision reference, and 64 guard slots past the output.
// Build: scripts/sycl-build.sh --backend=opencl unary_kernel.cpp -o unary_kernel && ./unary_kernel
#include <sycl/sycl.hpp>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <type_traits>

#define __dpct_inline__ inline
#define WARP_SIZE 16
#define SYCL_GLOBAL_ID_LOOP(K, ITEM) \
    for (auto i = ITEM.get_global_id(0); i < (size_t)K; i += ITEM.get_global_range(0))

static size_t ceil_div(const size_t m, const size_t n) {
    return (m + n - 1) / n;
}

// ---- element_wise.hpp: op_tanh, op_exp ----

// The bfloat16 branches of these helpers are dropped: this is the F32 oracle, and the nfcxx SYCL front end has no bfloat16.
template <typename T> static __dpct_inline__ T op_tanh(T x) {
    return sycl::tanh(x);
}
template <typename T> static __dpct_inline__ T op_exp(T x) {
    return sycl::exp(x);
}

// ---- element_wise.hpp: op_gelu, op_silu ----

template <typename T> static __dpct_inline__ T op_gelu(T x) {
    const T GELU_COEF_A    = static_cast<T>(0.044715f);
    const T SQRT_2_OVER_PI = static_cast<T>(0.79788456080286535587989211986876f);
    return static_cast<T>(0.5f) * x *
           (static_cast<T>(1.0f) +
            op_tanh(SQRT_2_OVER_PI * x * (static_cast<T>(1.0f) + GELU_COEF_A * x * x)));
}

template <typename T> static __dpct_inline__ T op_silu(T x) {
    return x / (static_cast<T>(1.0f) + op_exp(-x));
}

// ---- element_wise.cpp: op_relu, op_neg ----

template<typename T>
static __dpct_inline__ T op_relu(T x) {
    return sycl::fmax(x, static_cast<T>(0));
}
template<typename T>
static __dpct_inline__ T op_neg(T x) {
    return -x;
}

// ---- common.hpp: the fastdiv helpers ----

static const sycl::uint3 init_fastdiv_values(uint32_t d) {
    if (d == 0) {
        std::abort();  // GGML_ASSERT(d != 0) in common.hpp
    }

    uint32_t L = 0;
    while (L < 32 && (uint32_t{ 1 } << L) < d) {
        L++;
    }

    uint32_t mp = (uint32_t) ((uint64_t{ 1 } << 32) * ((uint64_t{ 1 } << L) - d) / d + 1);
    return sycl::uint3(mp, L, d);
}

// The high 32 bits of a*b. Upstream is sycl::mul_hi<unsigned>, which the nfcxx SYCL library lacks.
static __dpct_inline__ uint32_t mulhi32(uint32_t a, uint32_t b) {
    return (uint32_t) (((uint64_t) a * b) >> 32);
}

static __dpct_inline__ uint32_t fastdiv(uint32_t n, const sycl::uint3 fastdiv_values) {
    const uint32_t hi = mulhi32(n, fastdiv_values.x());
    return (hi + n) >> fastdiv_values.y();
}

static __dpct_inline__ sycl::uint2 fast_div_modulo(uint32_t n, const sycl::uint3 fastdiv_values) {
    const uint32_t div_val = fastdiv(n, fastdiv_values);
    const uint32_t mod_val = n - div_val * fastdiv_values.z();
    return sycl::uint2(div_val, mod_val);
}

// ---- element_wise.cpp: the kernels ----

template<typename T, typename F>
static void unary_op_flat_kernel(const T * x, T * dst, const int k, const sycl::nd_item<1> & item_ct1, const F & func) {
    SYCL_GLOBAL_ID_LOOP(k, item_ct1) {
        dst[i] = func(x[i]);
    }
}

template<typename T, typename F>
static void unary_op_generic_kernel(
        const T * x,
        T * dst,
        const int k,
        const sycl::uint3 ne0_fd, const sycl::uint3 ne1_fd, const sycl::uint3 ne2_fd,
        const size_t nb0,  const size_t nb1,  const size_t nb2,  const size_t nb3,
        const size_t nbd0, const size_t nbd1, const size_t nbd2, const size_t nbd3,
        const sycl::nd_item<1> & item_ct1,
        const F & func) {

    // 32-bit index math: k is int, so every logical index fits u32. 64-bit integer div/mod is
    // emulated on Xe and dominates this kernel otherwise, and even the 32-bit divide is worth
    // avoiding -- the divisors are launch-invariant, so the magic numbers are precomputed
    // host-side and each division becomes a multiply-high plus a shift.
    // Byte offsets are widened back to size_t only for the final address math.
    SYCL_GLOBAL_ID_LOOP(k, item_ct1) {
        sycl::uint2 dm = fast_div_modulo((uint32_t) i, ne0_fd);
        const uint32_t i0 = dm.y();
        dm = fast_div_modulo(dm.x(), ne1_fd);
        const uint32_t i1 = dm.y();
        dm = fast_div_modulo(dm.x(), ne2_fd);
        const uint32_t i2 = dm.y();
        const uint32_t i3 = dm.x();

        const char * src_base = (const char *) x;
        char       * dst_base = (char *) dst;

        const T * srcp = (const T *)(src_base + (size_t) i0*nb0  + (size_t) i1*nb1  + (size_t) i2*nb2  + (size_t) i3*nb3 );
        T *       dstp = (T *)(dst_base + (size_t) i0*nbd0 + (size_t) i1*nbd1 + (size_t) i2*nbd2 + (size_t) i3*nbd3);

        *dstp = func(*srcp);
    }
}

// ---- element_wise.cpp: ggml_sycl_op_unary's launch (the body of its dispatch lambda, F32) ----

template<typename F>
static void unary_launch(sycl::queue * stream, const float * src, float * dst_ptr, int k_elements, bool contiguous,
                         int64_t ne0, int64_t ne1, int64_t ne2,
                         size_t nb0, size_t nb1, size_t nb2, size_t nb3,
                         size_t nbd0, size_t nbd1, size_t nbd2, size_t nbd3, F func) {
    const int num_blocks = ceil_div(k_elements, 256);

    if (contiguous) {
        stream->parallel_for(
            sycl::nd_range<1>(sycl::range<1>(num_blocks) * sycl::range<1>(256),
                              sycl::range<1>(256)),
            [=](sycl::nd_item<1> item_ct1) [[sycl::reqd_sub_group_size(WARP_SIZE)]] {
                unary_op_flat_kernel(src, dst_ptr, k_elements, item_ct1, func);
            });
    } else {
        // Launch-invariant divisors: compute the magic numbers once on the host so the
        // kernel never issues an integer divide. Only the strided path needs them.
        const sycl::uint3 ne0_fd = init_fastdiv_values((uint32_t) ne0);
        const sycl::uint3 ne1_fd = init_fastdiv_values((uint32_t) ne1);
        const sycl::uint3 ne2_fd = init_fastdiv_values((uint32_t) ne2);
        stream->parallel_for(
            sycl::nd_range<1>(sycl::range<1>(num_blocks) * sycl::range<1>(256),
                              sycl::range<1>(256)),
            [=](sycl::nd_item<1> item_ct1) [[sycl::reqd_sub_group_size(WARP_SIZE)]] {
                unary_op_generic_kernel(
                    src, dst_ptr, k_elements,
                    ne0_fd, ne1_fd, ne2_fd,
                    nb0, nb1, nb2, nb3,
                    nbd0, nbd1, nbd2, nbd3,
                    item_ct1,
                    func
                );
            });
    }
}

// The four ops as ggml_sycl_op_neg / _relu / _silu / _gelu pass them (ggml's lambdas `[](auto x) { return op_X(x); }`,
// written as named functors: the nfcxx front end turns a closure temporary into a static global it cannot lower).
struct op_neg_fn  { template <typename T> T operator()(T x) const { return op_neg(x); } };
struct op_relu_fn { template <typename T> T operator()(T x) const { return op_relu(x); } };
struct op_silu_fn { template <typename T> T operator()(T x) const { return op_silu(x); } };
struct op_gelu_fn { template <typename T> T operator()(T x) const { return op_gelu(x); } };

static inline void launch_neg(sycl::queue * s, const float * x, float * d, int k, bool c, int64_t n0, int64_t n1, int64_t n2,
                              size_t a0, size_t a1, size_t a2, size_t a3, size_t b0, size_t b1, size_t b2, size_t b3) {
    const op_neg_fn f{};
    unary_launch(s, x, d, k, c, n0, n1, n2, a0, a1, a2, a3, b0, b1, b2, b3, f);
}
static inline void launch_relu(sycl::queue * s, const float * x, float * d, int k, bool c, int64_t n0, int64_t n1, int64_t n2,
                               size_t a0, size_t a1, size_t a2, size_t a3, size_t b0, size_t b1, size_t b2, size_t b3) {
    const op_relu_fn f{};
    unary_launch(s, x, d, k, c, n0, n1, n2, a0, a1, a2, a3, b0, b1, b2, b3, f);
}
static inline void launch_silu(sycl::queue * s, const float * x, float * d, int k, bool c, int64_t n0, int64_t n1, int64_t n2,
                               size_t a0, size_t a1, size_t a2, size_t a3, size_t b0, size_t b1, size_t b2, size_t b3) {
    const op_silu_fn f{};
    unary_launch(s, x, d, k, c, n0, n1, n2, a0, a1, a2, a3, b0, b1, b2, b3, f);
}
static inline void launch_gelu(sycl::queue * s, const float * x, float * d, int k, bool c, int64_t n0, int64_t n1, int64_t n2,
                               size_t a0, size_t a1, size_t a2, size_t a3, size_t b0, size_t b1, size_t b2, size_t b3) {
    const op_gelu_fn f{};
    unary_launch(s, x, d, k, c, n0, n1, n2, a0, a1, a2, a3, b0, b1, b2, b3, f);
}

// ---- host side ----

// The reference in double, as the spec gives it.
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

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

// One check: op over the ne shape, flat (contiguous src and dst) or strided (src row stride skips one element; dst contiguous).
static int check(sycl::queue & q, int op, const int64_t ne[4], bool strided, uint32_t seed) {
    const int64_t n = ne[0] * ne[1] * ne[2] * ne[3];
    // src view: row stride ne0 + 1 for the strided case (one skipped element per row)
    const int64_t pad = strided ? 1 : 0;
    const size_t  nb0 = sizeof(float);
    const size_t  nb1 = (size_t)(ne[0] + pad) * sizeof(float);
    const size_t  nb2 = nb1 * ne[1];
    const size_t  nb3 = nb2 * ne[2];
    const size_t  src_elems = (size_t)(nb3 * ne[3] / sizeof(float));
    const size_t  nbd0 = sizeof(float);
    const size_t  nbd1 = nbd0 * ne[0];
    const size_t  nbd2 = nbd1 * ne[1];
    const size_t  nbd3 = nbd2 * ne[2];

    float * src = sycl::malloc_shared<float>(src_elems, q);
    float * dst = sycl::malloc_shared<float>(n + 64, q);
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

    const bool contiguous = !strided;
    const int  k = (int) n;
    switch (op) {
        case 0: launch_neg (&q, src, dst, k, contiguous, ne[0], ne[1], ne[2], nb0, nb1, nb2, nb3, nbd0, nbd1, nbd2, nbd3); break;
        case 1: launch_relu(&q, src, dst, k, contiguous, ne[0], ne[1], ne[2], nb0, nb1, nb2, nb3, nbd0, nbd1, nbd2, nbd3); break;
        case 2: launch_silu(&q, src, dst, k, contiguous, ne[0], ne[1], ne[2], nb0, nb1, nb2, nb3, nbd0, nbd1, nbd2, nbd3); break;
        default: launch_gelu(&q, src, dst, k, contiguous, ne[0], ne[1], ne[2], nb0, nb1, nb2, nb3, nbd0, nbd1, nbd2, nbd3); break;
    }
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const double x    = (double) src[strided ? src_index(i) : i];
        const double want = ref_op(op, x);
        const double got  = (double) dst[i];
        const double err  = std::fabs(got - want);
        const double tol  = 1e-5 * std::max(1.0, std::fabs(want));
        if (!(err <= tol)) bad++;  // NaN fails too
        if (!std::isnan(err) && err > worst) worst = err;
    }
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("%s %lldx%lldx%lldx%lld %s: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           op_name(op), (long long)ne[0], (long long)ne[1], (long long)ne[2], (long long)ne[3],
           strided ? "strided" : "flat", (long long)bad, (long long)n, (long long)guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    const int64_t shapes[2][4] = { { 128, 2, 2, 2 }, { 5, 7, 11, 13 } };
    int failed = 0, total = 0;
    for (int op = 0; op < 4; op++) {
        for (int s = 0; s < 2; s++) {
            for (int strided = 0; strided < 2; strided++) {
                failed += check(q, op, shapes[s], strided != 0, 12345u + 7u * op + 31u * s + strided);
                total++;
            }
        }
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
