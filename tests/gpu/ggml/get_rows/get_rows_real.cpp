// The real ggml-sycl getrows.cpp (ggml/src/ggml-sycl/getrows.cpp, unchanged), compiled as this program's own TU through the
// nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first).
// SCOPE: this covers only the F32 and F16 kernels (get_rows_sycl_float<src0_t, dst_t>, the real launcher, called directly).
// It does NOT run the public ggml_sycl_op_get_rows dispatch: that switch is still blocked by the device pass refusing the
// quantized launchers' function-pointer template argument (dequantize_q1_0 "address of function"). The ggml helpers and
// the backend's ggml_sycl_info() come from libggml-sycl.so.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/soft_max/soft_max_real.cpp.
//
// Shapes: the table is (ne00 cols, ne01 rows, ne02 = 2 slices, 1); the index array is (ne10 indices, ne11 = 2, 1, 1), so
// dst is (ne00, ne10, 2, 1) and dst[c, i10, i11] = table[idx[i10, i11], c, i11]. The table values are integers in
// [-1024, 1024], exact in both F32 and F16, so the oracle is the table value itself and the copy must be bit-exact.
// 64 guard slots past the output must stay untouched.
#include "getrows.cpp"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static uint32_t gr_state = 0;
static uint32_t gr_next() {
    gr_state = gr_state * 1664525u + 1013904223u;
    return gr_state >> 8;
}

// One check: get_rows of a table of type src_type (GGML_TYPE_F32 or GGML_TYPE_F16) with the given shape.
static int gr_check(sycl::queue & q, ggml_backend_sycl_context & ctx, ggml_type src_type, const int64_t ne[4],
                    const int64_t nidx, uint32_t seed, const char * shape_name) {
    const int64_t cols = ne[0], rows = ne[1], slices = ne[2];
    const int64_t n_tab = cols * rows * slices;
    const int64_t n_out = cols * nidx * slices;
    const bool f16 = src_type == GGML_TYPE_F16;
    const char * tname = f16 ? "F16" : "F32";

    gr_state = seed;
    // table values: integers in [-1024, 1024], exact in F16
    std::vector<float> tab_vals(n_tab);
    for (int64_t i = 0; i < n_tab; i++) tab_vals[i] = (float) ((int) (gr_next() % 2049u) - 1024);

    void * tab = nullptr;
    if (f16) {
        sycl::half * h = sycl::malloc_shared<sycl::half>(n_tab, q);
        for (int64_t i = 0; i < n_tab; i++) h[i] = sycl::half(tab_vals[i]);
        tab = h;
    } else {
        float * f = sycl::malloc_shared<float>(n_tab, q);
        for (int64_t i = 0; i < n_tab; i++) f[i] = tab_vals[i];
        tab = f;
    }

    // indices: in [0, rows); the last row is included, so the output's row-tail path is covered
    int32_t * idx = sycl::malloc_shared<int32_t>(nidx * 2, q);
    for (int64_t i = 0; i < nidx * 2; i++) idx[i] = (int32_t) (gr_next() % (uint32_t) rows);
    idx[0] = (int32_t) (rows - 1);

    float * dst = sycl::malloc_shared<float>(n_out + 64, q);
    for (int64_t i = 0; i < n_out + 64; i++) dst[i] = -7.0f;  // guard tail past n_out must stay untouched

    ggml_tensor src0{};
    src0.type = src_type;
    for (int d = 0; d < 4; d++) src0.ne[d] = d < 3 ? ne[d] : 1;
    src0.nb[0] = ggml_type_size(src_type);
    src0.nb[1] = src0.nb[0] * cols;
    src0.nb[2] = src0.nb[1] * rows;
    src0.nb[3] = src0.nb[2] * slices;
    src0.data = tab;

    ggml_tensor idx_t{};
    idx_t.type = GGML_TYPE_I32;
    idx_t.ne[0] = nidx; idx_t.ne[1] = 2; idx_t.ne[2] = 1; idx_t.ne[3] = 1;
    idx_t.nb[0] = sizeof(int32_t);
    idx_t.nb[1] = idx_t.nb[0] * nidx;
    idx_t.nb[2] = idx_t.nb[1] * 2;
    idx_t.nb[3] = idx_t.nb[2];
    idx_t.data = idx;

    ggml_tensor dst_t{};
    dst_t.type = GGML_TYPE_F32;
    dst_t.ne[0] = cols; dst_t.ne[1] = nidx; dst_t.ne[2] = slices; dst_t.ne[3] = 1;
    dst_t.nb[0] = sizeof(float);
    dst_t.nb[1] = dst_t.nb[0] * cols;
    dst_t.nb[2] = dst_t.nb[1] * nidx;
    dst_t.nb[3] = dst_t.nb[2] * slices;
    dst_t.data = dst;
    dst_t.src[0] = &src0;
    dst_t.src[1] = &idx_t;
    dst_t.src[2] = nullptr;

    // Scope: this calls the real F32 and F16 kernel launcher (get_rows_sycl_float) directly. The public dispatch
    // ggml_sycl_op_get_rows is not called: its switch instantiates the quantized get_rows_sycl<..., dequantize_*> launchers,
    // which pass a function pointer as a template argument, and the device pass refuses that ("address of function").
    if (f16) {
        get_rows_sycl_float<sycl::half, float>(ctx, &src0, &idx_t, &dst_t, (const sycl::half *) tab, idx, dst, &q);
    } else {
        get_rows_sycl_float<float, float>(ctx, &src0, &idx_t, &dst_t, (const float *) tab, idx, dst, &q);
    }
    q.wait();

    int64_t bad = 0, guard = 0;
    for (int64_t i11 = 0; i11 < 2 && i11 < slices; i11++) {
        for (int64_t i10 = 0; i10 < nidx; i10++) {
            const int64_t r = idx[i10 + i11 * nidx];
            for (int64_t c = 0; c < cols; c++) {
                const float want = tab_vals[r * cols + i11 * cols * rows + c];
                const float got  = dst[c + i10 * cols + i11 * cols * nidx];
                if (got != want) bad++;  // exact: the copy is bit-exact for these values
            }
        }
    }
    for (int64_t i = n_out; i < n_out + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("get_rows %s %s: mismatches: %lld of %lld, guard writes: %lld of 64: %s\n",
           tname, shape_name, (long long) bad, (long long) n_out, (long long) guard, ok ? "ok" : "FAIL");

    sycl::free(tab, q);
    sycl::free(idx, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t shapes[2][4] = { { 64, 5, 2, 1 }, { 128, 9, 2, 1 } };
    const int64_t nidx[2]     = { 7, 13 };
    const char *  names[2]    = { "64x5x2 idx7", "128x9x2 idx13" };
    int failed = 0, checks = 0;
    for (int s = 0; s < 2; s++) {
        for (int t = 0; t < 2; t++) {
            const ggml_type ty = t ? GGML_TYPE_F16 : GGML_TYPE_F32;
            failed += gr_check(q, ctx, ty, shapes[s], nidx[s], 4242u + 31u * s + 7u * t, names[s]);
            checks++;
        }
    }
    printf("checks: %d, failed: %d\n", checks, failed);
    return failed != 0;
}
