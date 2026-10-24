// The real ggml-sycl pad.cpp (ggml/src/ggml-sycl/pad.cpp, unchanged), compiled as this program's own TU through the
// nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first).
// The ggml helpers (ggml_type_size) and the backend's globals come from libggml-sycl.so and libggml-base.so. Same link
// discipline as fill_real: a version script keeps every symbol of this executable local (see fill_real.cpp).
//
// The op is ggml_sycl_op_pad (GGML_OP_PAD, F32): dst = src padded by lpN zeros before and rpN after in each dimension N.
// Every output element is checked against a host reference and 64 guard slots past the end must stay put. With a
// nonzero `extra`, the source rows are strided (nb1 = (ne0 + extra) * 4), as for the non-contiguous test_pad_ext cases.
// argv: ne0 ne1 ne2 ne3 lp0 rp0 lp1 rp1 lp2 rp2 lp3 rp3 extra (ne are the source's).
#include "pad.cpp"
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char ** argv) {
    if (argc != 14) { fprintf(stderr, "usage: %s ne0 ne1 ne2 ne3 lp0 rp0 lp1 rp1 lp2 rp2 lp3 rp3 extra\n", argv[0]); return 2; }
    int64_t sne[4];
    int32_t p[8];
    for (int i = 0; i < 4; i++) sne[i] = atoll(argv[1 + i]);
    for (int i = 0; i < 8; i++) p[i] = atoi(argv[5 + i]);
    const int64_t extra = atoll(argv[13]);

    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    int64_t dne[4];
    for (int i = 0; i < 4; i++) dne[i] = sne[i] + p[2 * i] + p[2 * i + 1];
    const int64_t row = sne[0] + extra;                       // source row pitch in elements
    const int64_t n_src = row * sne[1] * sne[2] * sne[3];
    const int64_t n_dst = dne[0] * dne[1] * dne[2] * dne[3];
    const int64_t n_guard = 64;

    float * src = sycl::malloc_shared<float>(n_src, q);
    float * dst = sycl::malloc_shared<float>(n_dst + n_guard, q);
    for (int64_t i = 0; i < n_src; i++) src[i] = 1.0f + (float)i;   // distinct, nonzero values
    for (int64_t i = 0; i < n_dst + n_guard; i++) dst[i] = -7.0f;   // the output and the guard tail start at -7

    ggml_tensor s{};
    s.type = GGML_TYPE_F32;
    for (int i = 0; i < 4; i++) s.ne[i] = sne[i];
    s.nb[0] = sizeof(float); s.nb[1] = s.nb[0] * row; s.nb[2] = s.nb[1] * s.ne[1]; s.nb[3] = s.nb[2] * s.ne[2];
    s.data = src;

    ggml_tensor t{};
    t.type = GGML_TYPE_F32;
    for (int i = 0; i < 4; i++) t.ne[i] = dne[i];
    t.nb[0] = sizeof(float); t.nb[1] = t.nb[0] * t.ne[0]; t.nb[2] = t.nb[1] * t.ne[1]; t.nb[3] = t.nb[2] * t.ne[2];
    t.data = dst;
    t.src[0] = &s;
    for (int i = 0; i < 8; i++) t.op_params[i] = p[i];

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;
    ggml_sycl_op_pad(ctx, &t);
    q.wait();

    int64_t bad = 0, guard = 0;
    for (int64_t i3 = 0; i3 < dne[3]; i3++)
    for (int64_t i2 = 0; i2 < dne[2]; i2++)
    for (int64_t i1 = 0; i1 < dne[1]; i1++)
    for (int64_t i0 = 0; i0 < dne[0]; i0++) {
        const int64_t j0 = i0 - p[0], j1 = i1 - p[2], j2 = i2 - p[4], j3 = i3 - p[6];
        const bool in = j0 >= 0 && j0 < sne[0] && j1 >= 0 && j1 < sne[1] && j2 >= 0 && j2 < sne[2] && j3 >= 0 && j3 < sne[3];
        const float want = in ? src[((j3 * sne[2] + j2) * sne[1] + j1) * row + j0] : 0.0f;
        bad += dst[((i3 * dne[2] + i2) * dne[1] + i1) * dne[0] + i0] != want;
    }
    for (int64_t i = n_dst; i < n_dst + n_guard; i++) guard += dst[i] != -7.0f;
    printf("mismatches: %lld of %lld, guard writes: %lld of 64\n", (long long)bad, (long long)n_dst, (long long)guard);
    sycl::free(src, q);
    sycl::free(dst, q);
    return bad != 0 || guard != 0;
}
