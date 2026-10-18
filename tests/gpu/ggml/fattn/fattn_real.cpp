// The real ggml-sycl vector flash-attention kernel (ggml/src/ggml-sycl/fattn-vec.hpp, unchanged), compiled as this program's own
// TU through the nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir
// first). The entry point is ggml_sycl_flash_attn_ext_vec_case<64, F16, F16>, the template that fattn.cpp's dispatcher
// (ggml_sycl_flash_attn_ext_vec, FATTN_VEC_CASE) calls for an F16 K and V with head size 64. It launches flash_attn_ext_vec
// through launch_fattn (fattn-common.hpp) and the work-group-static local memory, sub-group reductions and half2 math of the
// kernel. ggml_sycl_fattn_get_extra and the backend's ggml_sycl_info() come from libggml-sycl.so. The dispatcher itself
// (fattn.cpp) is not included: it pulls in the oneMKL and oneDNN flash-attention variants, and the vec case is what it runs for
// this shape.
//
// Shapes (D = 64, F32 Q, F16 K and V, F32 output, no mask, no sinks, no logit softcap, scale 1/sqrt(64), no ALiBi):
//   gqa2 decode: 1 token, 4 query heads over 2 KV heads, 200 keys (not a multiple of the 128-thread block's key tile)
//   gqa2 prefill: 3 tokens (the two-column path with a tail column), 4 heads over 2 KV heads, 130 keys
//   mha: 1 token, 2 heads over 2 KV heads, 300 keys (no grouped query attention)
//   gqa4 short: 1 token, 8 heads over 2 KV heads, 77 keys (fewer keys than the tile)
// The oracle is softmax(Q K^T * scale) V in double precision, over the F16 values the kernel reads (K and V are rounded to
// half first, as the input is). Each element of the output is checked at 2e-2 absolute error (the kernel accumulates the
// softmax in half2 and Q is scaled in half, so the tolerance is the kernel's own precision, not a loose bound); 64 guard slots
// past the output must stay untouched.
#include "fattn-vec.hpp"

// fattn-vec.hpp declares this instance extern (it is instantiated in libggml-sycl.so, on that library's real sycl::queue).
// This program's queue is the nfcxx SYCL subset's, so the explicit instantiation definition below makes this TU compile its
// own copy of the vec case and its kernel, and the call binds to that copy.
template void ggml_sycl_flash_attn_ext_vec_case<64, GGML_TYPE_F16, GGML_TYPE_F16>(ggml_backend_sycl_context & ctx, ggml_tensor * dst);

#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

// The inputs: a fixed LCG over [-1, 1), so the run is repeatable.
static float fa_next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 2.0f - 1.0f;
}

struct fa_shape {
    int64_t     n_head;
    int64_t     n_head_kv;
    int64_t     n_tokens;
    int64_t     n_kv;
    const char * name;
};

static constexpr int64_t FA_D = 64;  // head size; the vec case is instantiated for D = 64

// The scratch pool of the backend context. ggml_backend_sycl_context::pool() would build one with libggml-sycl's
// new_pool_for_device(queue), which reads a real sycl::queue; this program's queue is the nfcxx SYCL subset's, so the harness
// supplies a pool of its own (shared USM from its queue) in pools[0], which pool() returns without building one.
struct fa_pool : ggml_sycl_pool {
    sycl::queue & q;
    explicit fa_pool(sycl::queue & queue) : q(queue) {}
    void * alloc(size_t size, size_t * actual_size) override {
        const size_t n = size > 0 ? size : 1;
        *actual_size = n;
        return sycl::malloc_shared<char>(n, q);
    }
    void free(void * ptr, size_t) override { sycl::free(ptr, q); }
};

static int fa_check(sycl::queue & q, ggml_backend_sycl_context & ctx, const fa_shape & sh, uint32_t seed) {
    const int64_t H = sh.n_head, HK = sh.n_head_kv, T = sh.n_tokens, N = sh.n_kv, D = FA_D;
    const int64_t nq = D * T * H, nkv = D * N * HK, nd = D * H * T;

    float *      Q   = sycl::malloc_shared<float>(nq, q);
    sycl::half * K   = sycl::malloc_shared<sycl::half>(nkv, q);
    sycl::half * V   = sycl::malloc_shared<sycl::half>(nkv, q);
    float *      dst = sycl::malloc_shared<float>(nd + 64, q);

    uint32_t state = seed;
    for (int64_t i = 0; i < nq; i++) Q[i] = fa_next_value(state);
    for (int64_t i = 0; i < nkv; i++) K[i] = sycl::half(fa_next_value(state));
    for (int64_t i = 0; i < nkv; i++) V[i] = sycl::half(fa_next_value(state));
    const float guard = -7.0f;
    for (int64_t i = 0; i < nd + 64; i++) dst[i] = guard;  // guard tail past nd must stay untouched

    // ggml layouts: Q [D, T, H, 1] F32, K and V [D, N, HK, 1] F16, dst [D, H, T, 1] F32 (the KQV permutation of flash_attn_ext)
    ggml_tensor Q_t{}, K_t{}, V_t{}, dst_t{};
    Q_t.type = GGML_TYPE_F32;
    Q_t.ne[0] = D; Q_t.ne[1] = T; Q_t.ne[2] = H; Q_t.ne[3] = 1;
    Q_t.nb[0] = sizeof(float); Q_t.nb[1] = Q_t.nb[0] * D; Q_t.nb[2] = Q_t.nb[1] * T; Q_t.nb[3] = Q_t.nb[2] * H;
    Q_t.data = Q;

    K_t.type = GGML_TYPE_F16;
    K_t.ne[0] = D; K_t.ne[1] = N; K_t.ne[2] = HK; K_t.ne[3] = 1;
    K_t.nb[0] = sizeof(sycl::half); K_t.nb[1] = K_t.nb[0] * D; K_t.nb[2] = K_t.nb[1] * N; K_t.nb[3] = K_t.nb[2] * HK;
    K_t.data = K;

    V_t.type = GGML_TYPE_F16;
    V_t.ne[0] = D; V_t.ne[1] = N; V_t.ne[2] = HK; V_t.ne[3] = 1;
    V_t.nb[0] = sizeof(sycl::half); V_t.nb[1] = V_t.nb[0] * D; V_t.nb[2] = V_t.nb[1] * N; V_t.nb[3] = V_t.nb[2] * HK;
    V_t.data = V;

    dst_t.type = GGML_TYPE_F32;
    dst_t.ne[0] = D; dst_t.ne[1] = H; dst_t.ne[2] = T; dst_t.ne[3] = 1;
    dst_t.nb[0] = sizeof(float); dst_t.nb[1] = dst_t.nb[0] * D; dst_t.nb[2] = dst_t.nb[1] * H; dst_t.nb[3] = dst_t.nb[2] * T;
    dst_t.data = dst;
    dst_t.src[0] = &Q_t;
    dst_t.src[1] = &K_t;
    dst_t.src[2] = &V_t;
    dst_t.src[3] = nullptr;  // no mask
    dst_t.src[4] = nullptr;  // no sinks
    // op_params: [0] scale (float), [1] max_bias (float, 0: no ALiBi), [2] logit_softcap (float, 0: off)
    const float scale = 1.0f / std::sqrt((float) D), max_bias = 0.0f, logit_softcap = 0.0f;
    int32_t * p = dst_t.op_params;
    memcpy(&p[0], &scale, sizeof(float));
    memcpy(&p[1], &max_bias, sizeof(float));
    memcpy(&p[2], &logit_softcap, sizeof(float));

    ggml_sycl_flash_attn_ext_vec_case<64, GGML_TYPE_F16, GGML_TYPE_F16>(ctx, &dst_t);
    q.wait();

    // reference: for query head h at token t, the KV head is h / (H / HK), as in the kernel (head / gqa_ratio)
    const int64_t gqa = H / HK;
    const double  dscale = 1.0 / std::sqrt((double) D);
    std::vector<double> s((size_t) N);
    int64_t bad = 0, guard_w = 0;
    double  worst = 0.0;
    const double tol = 2e-2;
    for (int64_t t = 0; t < T; t++) {
        for (int64_t h = 0; h < H; h++) {
            const int64_t hk = h / gqa;
            double smax = -std::numeric_limits<double>::infinity();
            for (int64_t k = 0; k < N; k++) {
                double dot = 0.0;
                for (int64_t d = 0; d < D; d++) {
                    dot += (double) Q[d + D * (t + T * h)] * (double) (float) K[d + D * (k + N * hk)];
                }
                s[(size_t) k] = dot * dscale;
                if (s[(size_t) k] > smax) smax = s[(size_t) k];
            }
            double sum = 0.0;
            for (int64_t k = 0; k < N; k++) {
                s[(size_t) k] = std::exp(s[(size_t) k] - smax);
                sum += s[(size_t) k];
            }
            for (int64_t d = 0; d < D; d++) {
                double want = 0.0;
                for (int64_t k = 0; k < N; k++) {
                    want += (s[(size_t) k] / sum) * (double) (float) V[d + D * (k + N * hk)];
                }
                const double got = (double) dst[d + D * (h + H * t)];
                const double err = std::fabs(got - want);
                if (!(err <= tol)) bad++;  // NaN fails too
                if (!std::isnan(err) && err > worst) worst = err;
            }
        }
    }
    for (int64_t i = nd; i < nd + 64; i++) guard_w += (float) dst[i] != guard;

    const int64_t total = nd;
    const bool    ok    = bad == 0 && guard_w == 0;
    printf("fattn F16 %s: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n", sh.name,
           (long long) bad, (long long) total, (long long) guard_w, worst, ok ? "ok" : "FAIL");
    sycl::free(Q, q);
    sycl::free(K, q);
    sycl::free(V, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;
    ctx.pools[0].reset(new fa_pool(q));

    const fa_shape shapes[4] = {
        { 4, 2, 1, 200, "gqa2 decode H4 HK2 T1 N200" },
        { 4, 2, 3, 130, "gqa2 prefill H4 HK2 T3 N130" },
        { 2, 2, 1, 300, "mha H2 HK2 T1 N300" },
        { 8, 2, 1, 77, "gqa4 short H8 HK2 T1 N77" },
    };
    int failed = 0, checks = 0;
    for (int s = 0; s < 4; s++) {
        failed += fa_check(q, ctx, shapes[s], 4242u + 31u * (uint32_t) s) != 0;
        checks++;
    }
    printf("checks: %d, failed: %d\n", checks, failed);
    return failed != 0;
}
