// The real ggml-sycl diag.cpp (ggml/src/ggml-sycl/diag.cpp, unchanged), compiled as this program's own TU through the
// nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first).
// The ggml helpers and the backend's ggml_sycl_info() / get_current_device_id() / g_ggml_sycl_debug come from
// libggml-sycl.so (linked with -lggml-sycl). Same link discipline as fill_real: a version script keeps every symbol of
// this executable local, so the TU's dpct helper copies do not interpose libggml-sycl's (see fill_real.cpp).
//
// The op is ggml_sycl_op_diag (inline in diag.cpp) on a source of shape {ne0, 1, ne2, ne3} into {ne0, ne0, ne2, ne3}:
// every output element is checked (the source on the diagonal, zero off it) and 64 guard slots past the end must stay put.
// argv: ne0 ne1 ne2 ne3 (ne1 must be 1, as the op asserts).
#include "diag.cpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char ** argv) {
    if (argc != 5) { fprintf(stderr, "usage: %s ne0 ne1 ne2 ne3\n", argv[0]); return 2; }
    const int64_t ne0 = atoll(argv[1]), ne1 = atoll(argv[2]), ne2 = atoll(argv[3]), ne3 = atoll(argv[4]);
    if (ne1 != 1) { fprintf(stderr, "ne1 must be 1\n"); return 2; }

    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    const int64_t n_src = ne0 * ne1 * ne2 * ne3;     // src is {ne0, 1, ne2, ne3}
    const int64_t n_dst = ne0 * ne0 * ne2 * ne3;     // dst is {ne0, ne0, ne2, ne3}
    const int64_t n_guard = 64;

    float * src = sycl::malloc_shared<float>(n_src, q);
    float * dst = sycl::malloc_shared<float>(n_dst + n_guard, q);
    for (int64_t i = 0; i < n_src; i++) src[i] = 1.0f + (float)i;   // distinct, nonzero values
    for (int64_t i = 0; i < n_dst + n_guard; i++) dst[i] = -7.0f;   // the output and the guard tail start at -7

    ggml_tensor s{};
    s.type = GGML_TYPE_F32;
    s.ne[0] = ne0; s.ne[1] = ne1; s.ne[2] = ne2; s.ne[3] = ne3;
    s.nb[0] = sizeof(float); s.nb[1] = s.nb[0] * s.ne[0]; s.nb[2] = s.nb[1] * s.ne[1]; s.nb[3] = s.nb[2] * s.ne[2];
    s.data = src;

    ggml_tensor t{};
    t.type = GGML_TYPE_F32;
    t.ne[0] = ne0; t.ne[1] = ne0; t.ne[2] = ne2; t.ne[3] = ne3;
    t.nb[0] = sizeof(float); t.nb[1] = t.nb[0] * t.ne[0]; t.nb[2] = t.nb[1] * t.ne[1]; t.nb[3] = t.nb[2] * t.ne[2];
    t.data = dst;
    t.src[0] = &s;

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;
    ggml_sycl_op_diag(ctx, &t);
    q.wait();

    int64_t bad = 0, guard = 0;
    for (int64_t i3 = 0; i3 < ne3; i3++)
    for (int64_t i2 = 0; i2 < ne2; i2++)
    for (int64_t i1 = 0; i1 < ne0; i1++)
    for (int64_t i0 = 0; i0 < ne0; i0++) {
        const int64_t idx = ((i3 * ne2 + i2) * ne0 + i1) * ne0 + i0;
        const float want = i0 == i1 ? src[(i3 * ne2 + i2) * ne0 + i0] : 0.0f;
        bad += dst[idx] != want;
    }
    for (int64_t i = n_dst; i < n_dst + n_guard; i++) guard += dst[i] != -7.0f;
    printf("mismatches: %lld of %lld, guard writes: %lld of 64\n", (long long)bad, (long long)n_dst, (long long)guard);
    sycl::free(src, q);
    sycl::free(dst, q);
    return bad != 0 || guard != 0;
}
