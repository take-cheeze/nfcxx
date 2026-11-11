// The real ggml-sycl cpy.cpp (ggml/src/ggml-sycl/cpy.cpp, unchanged), compiled as this program's own TU through the nfcxx SYCL
// flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first). The entry point
// is the real ggml_sycl_cpy(ctx, src0, src1) for F32 -> F16, which takes two tensors (src1 is the destination); the ggml
// helpers and the backend's ggml_sycl_info() come from libggml-sycl.so.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/fill_real/fill_real.cpp.
//
// Checks: F32 source, F16 destination (contiguous), flat (contiguous source) and strided (source row stride skips one
// element), two shapes, 64 guard slots past the destination. Each F16 element is compared with the F32 input rounded to F16
// (round to nearest): |out - in| <= 1e-3 * max(1, |in|) (half has 11 significant bits, so the rounding error is at most
// 2^-11 relative). The guard slots must stay untouched (their bytes are compared).
#include "cpy.cpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

// One check: a src of shape ne (F32, flat or with a row stride that skips one element) copied to a contiguous F16 dst.
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, const int64_t ne[4], bool strided, uint32_t seed) {
    const int64_t n = ne[0] * ne[1] * ne[2] * ne[3];
    const int64_t pad = strided ? 1 : 0;
    const size_t  nb1 = (size_t)(ne[0] + pad) * sizeof(float);
    const size_t  nb2 = nb1 * ne[1];
    const size_t  nb3 = nb2 * ne[2];
    const size_t  src_bytes = nb3 * ne[3];

    char * src = (char *) sycl::malloc_shared<unsigned char>(src_bytes, q);
    sycl::half * dst = sycl::malloc_shared<sycl::half>(n + 64, q);
    uint32_t state = seed;
    for (int64_t i3 = 0; i3 < ne[3]; i3++)
        for (int64_t i2 = 0; i2 < ne[2]; i2++)
            for (int64_t i1 = 0; i1 < ne[1]; i1++)
                for (int64_t i0 = 0; i0 < ne[0] + pad; i0++) {
                    float v = next_value(state);
                    if (i0 < ne[0]) *(float *) (src + i3 * nb3 + i2 * nb2 + i1 * nb1 + i0 * sizeof(float)) = v;
                }
    const uint16_t guard_bits = 0x5A5A;
    for (int64_t i = 0; i < n + 64; i++) std::memcpy((char *) (dst + i), &guard_bits, sizeof(uint16_t));

    ggml_tensor src0{};
    src0.type = GGML_TYPE_F32;
    for (int d = 0; d < 4; d++) src0.ne[d] = ne[d];
    src0.nb[0] = sizeof(float); src0.nb[1] = nb1; src0.nb[2] = nb2; src0.nb[3] = nb3;
    src0.data = src;

    ggml_tensor dst_t{};
    dst_t.type = GGML_TYPE_F16;
    for (int d = 0; d < 4; d++) dst_t.ne[d] = ne[d];
    dst_t.nb[0] = sizeof(sycl::half);
    dst_t.nb[1] = dst_t.nb[0] * ne[0];
    dst_t.nb[2] = dst_t.nb[1] * ne[1];
    dst_t.nb[3] = dst_t.nb[2] * ne[2];
    dst_t.data = dst;

    ggml_sycl_cpy(ctx, &src0, &dst_t);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t i = 0; i < n; i++) {
        const int64_t i0 = i % ne[0];
        const int64_t i1 = (i / ne[0]) % ne[1];
        const int64_t i2 = (i / (ne[0] * ne[1])) % ne[2];
        const int64_t i3 = i / (ne[0] * ne[1] * ne[2]);
        const float in = *(const float *) (src + i3 * nb3 + i2 * nb2 + i1 * nb1 + i0 * sizeof(float));
        const double got = (double) (float) dst[i];
        const double err = std::fabs(got - (double) in);
        const double tol = 1e-3 * std::max(1.0, std::fabs((double) in));
        if (!(err <= tol)) bad++;  // NaN fails too
        if (!std::isnan(err) && err > worst) worst = err;
    }
    for (int64_t i = n; i < n + 64; i++) {
        uint16_t bits;
        std::memcpy(&bits, (char *) (dst + i), sizeof(uint16_t));
        guard += bits != guard_bits;
    }

    const bool ok = bad == 0 && guard == 0;
    printf("cpy F32 F16 %lldx%lldx%lldx%lld %s: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           (long long) ne[0], (long long) ne[1], (long long) ne[2], (long long) ne[3],
           strided ? "strided" : "flat", (long long) bad, (long long) n, (long long) guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t shapes[2][4] = { { 128, 2, 2, 2 }, { 5, 7, 11, 13 } };
    int failed = 0, total = 0;
    for (int s = 0; s < 2; s++) {
        for (int strided = 0; strided < 2; strided++) {
            failed += check(q, ctx, shapes[s], strided != 0, 4242u + 17u * s + strided);
            total++;
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
