// The real ggml-sycl concat.cpp (ggml/src/ggml-sycl/concat.cpp, unchanged), compiled as this program's own TU through the
// nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first). The
// entry point is the real ggml_sycl_op_concat, called with a ggml_backend_sycl_context and a ggml_tensor whose src[0] and
// src[1] are the two inputs and whose op_params[0] is the dim; the ggml helpers and the backend's ggml_sycl_info() come from
// libggml-sycl.so.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/fill_real/fill_real.cpp.
//
// Checks: F32, contiguous inputs, concatenation along dim 0, 1 and 2 (dim 3 takes the memcpy path, not checked here), two
// base shapes; src1 has 3 slices along the dim. Every element of dst is compared bit-exactly against the expected value
// computed from the inputs, and 64 guard slots past the output must stay untouched.
#include "concat.cpp"
#include <cmath>
#include <cstdio>
#include <cstring>

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

static ggml_tensor make_tensor(const int64_t ne[4], void * data) {
    ggml_tensor t{};
    t.type = GGML_TYPE_F32;
    for (int d = 0; d < 4; d++) t.ne[d] = ne[d];
    t.nb[0] = sizeof(float);
    t.nb[1] = t.nb[0] * ne[0];
    t.nb[2] = t.nb[1] * ne[1];
    t.nb[3] = t.nb[2] * ne[2];
    t.data = data;
    return t;
}

static int64_t prod(const int64_t ne[4]) { return ne[0] * ne[1] * ne[2] * ne[3]; }

// One check: a (shape of src0) and b (shape of src1) differ only along dim, where b has 3 slices.
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, const int64_t a[4], int dim, uint32_t seed) {
    int64_t b[4], c[4];
    for (int d = 0; d < 4; d++) { b[d] = a[d]; c[d] = a[d]; }
    b[dim] = 3;
    c[dim] = a[dim] + 3;
    const int64_t na = prod(a), nb = prod(b), nc = prod(c);

    float * s0  = sycl::malloc_shared<float>(na, q);
    float * s1  = sycl::malloc_shared<float>(nb, q);
    float * dst = sycl::malloc_shared<float>(nc + 64, q);
    uint32_t state = seed;
    for (int64_t i = 0; i < na; i++) s0[i] = next_value(state);
    for (int64_t i = 0; i < nb; i++) s1[i] = next_value(state);
    for (int64_t i = 0; i < nc + 64; i++) dst[i] = -7.0f;  // guard tail past nc must stay untouched

    ggml_tensor t0 = make_tensor(a, s0);
    ggml_tensor t1 = make_tensor(b, s1);
    ggml_tensor td = make_tensor(c, dst);
    td.src[0] = &t0;
    td.src[1] = &t1;
    ((int32_t *) td.op_params)[0] = dim;

    ggml_sycl_op_concat(ctx, &td);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t i = 0; i < nc; i++) {
        // coordinates of element i in dst (row-major over c)
        int64_t k[4];
        int64_t r = i;
        for (int d = 0; d < 4; d++) { k[d] = r % c[d]; r /= c[d]; }
        float want;
        if (k[dim] < a[dim]) {
            int64_t j = k[0] + a[0] * (k[1] + a[1] * (k[2] + a[2] * k[3]));
            want = s0[j];
        } else {
            k[dim] -= a[dim];
            int64_t j = k[0] + b[0] * (k[1] + b[1] * (k[2] + b[2] * k[3]));
            want = s1[j];
        }
        const double err = std::fabs((double) dst[i] - (double) want);
        if (dst[i] != want) bad++;
        if (!std::isnan(err) && err > worst) worst = err;
    }
    for (int64_t i = nc; i < nc + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("concat F32 %lldx%lldx%lldx%lld dim %d: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           (long long) a[0], (long long) a[1], (long long) a[2], (long long) a[3], dim,
           (long long) bad, (long long) nc, (long long) guard, worst, ok ? "ok" : "FAIL");
    sycl::free(s0, q);
    sycl::free(s1, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t shapes[2][4] = { { 8, 6, 4, 2 }, { 16, 5, 3, 2 } };
    int failed = 0, total = 0;
    for (int s = 0; s < 2; s++) {
        for (int dim = 0; dim < 3; dim++) {
            failed += check(q, ctx, shapes[s], dim, 777u + 13u * s + dim);
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
