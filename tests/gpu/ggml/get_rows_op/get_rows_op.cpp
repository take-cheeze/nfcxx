// The real ggml-sycl getrows.cpp (ggml/src/ggml-sycl/getrows.cpp, unchanged), compiled as this program's own TU through the
// nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first). The
// entry point is the public ggml_sycl_op_get_rows, the whole switch over the source types (its F32, F16 and I32 arms and
// the quantized launchers, which all compile now that PR #425 fixed the function-pointer template argument). Only F32 and
// F16 tables are run here. The ggml helpers and the backend's ggml_sycl_info() come from libggml-sycl.so.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/fill_real/fill_real.cpp.
//
// Shapes: the table is (ne00 cols, ne01 rows, ne02 = 2 slices, 1); the index array is (ne10 indices, ne11 = 2, 1, 1), so
// dst is (ne00, ne10, 2, 1) and dst[c, i10, i11] = table[idx[i10, i11], c, i11]. The table values are small integers (exact
// in both types), so every output element is compared bit-exactly against the table, and 64 guard slots past the output
// must stay untouched.
#include "getrows.cpp"
#include <cstdio>
#include <cstring>

static ggml_tensor make_tensor(ggml_type type, const int64_t ne[4], void * data) {
    ggml_tensor t{};
    t.type = type;
    for (int d = 0; d < 4; d++) t.ne[d] = ne[d];
    t.nb[0] = ggml_type_size(type);
    t.nb[1] = t.nb[0] * ne[0];
    t.nb[2] = t.nb[1] * ne[1];
    t.nb[3] = t.nb[2] * ne[2];
    t.data = data;
    return t;
}

// One check: the table of type T (F32 or F16) with cols x rows x 2 values, nidx indices per slice.
template <typename T>
static int check(sycl::queue & q, ggml_backend_sycl_context & ctx, ggml_type type, int64_t cols, int64_t rows, int64_t nidx) {
    const int64_t tab_n = cols * rows * 2;
    T * tab = sycl::malloc_shared<T>(tab_n, q);
    int32_t * idx = sycl::malloc_shared<int32_t>(nidx * 2, q);
    float * dst = sycl::malloc_shared<float>(cols * nidx * 2 + 64, q);  // ggml's get_rows writes F32 (or I32) rows
    // table value at (c, r, s): a small integer, distinct per position (exact in F16)
    for (int64_t s = 0; s < 2; s++)
        for (int64_t r = 0; r < rows; r++)
            for (int64_t c = 0; c < cols; c++)
                tab[c + cols * (r + rows * s)] = static_cast<T>((float) ((c * 7 + r * 13 + s * 3) % 251) - 125.0f);
    for (int64_t i = 0; i < nidx * 2; i++) idx[i] = (int32_t) ((i * 5 + 1) % rows);
    for (int64_t i = 0; i < cols * nidx * 2 + 64; i++) dst[i] = -7.0f;  // guard tail must stay untouched

    const int64_t ne_tab[4] = { cols, rows, 2, 1 };
    const int64_t ne_idx[4] = { nidx, 2, 1, 1 };
    const int64_t ne_dst[4] = { cols, nidx, 2, 1 };
    ggml_tensor src0 = make_tensor(type, ne_tab, tab);
    ggml_tensor idx_t = make_tensor(GGML_TYPE_I32, ne_idx, idx);
    ggml_tensor dst_t = make_tensor(GGML_TYPE_F32, ne_dst, dst);
    dst_t.src[0] = &src0;
    dst_t.src[1] = &idx_t;

    ggml_sycl_op_get_rows(ctx, &dst_t);
    q.wait();

    int64_t bad = 0, guard = 0;
    for (int64_t i11 = 0; i11 < 2; i11++) {
        for (int64_t i10 = 0; i10 < nidx; i10++) {
            const int64_t r = idx[i10 + i11 * nidx];
            for (int64_t c = 0; c < cols; c++) {
                const T want = tab[c + cols * (r + rows * i11)];
                const float got = dst[c + i10 * cols + i11 * cols * nidx];
                if (got != (float) want) bad++;
            }
        }
    }
    for (int64_t i = cols * nidx * 2; i < cols * nidx * 2 + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("get_rows %s %lldx%lldx2 idx %lld: mismatches: %lld of %lld, guard writes: %lld of 64: %s\n",
           type == GGML_TYPE_F32 ? "F32" : "F16", (long long) cols, (long long) rows, (long long) nidx,
           (long long) bad, (long long) (cols * nidx * 2), (long long) guard, ok ? "ok" : "FAIL");
    sycl::free(tab, q);
    sycl::free(idx, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    int failed = 0;
    failed += check<float>(q, ctx, GGML_TYPE_F32, 64, 5, 7);
    failed += check<float>(q, ctx, GGML_TYPE_F32, 128, 9, 13);
    failed += check<sycl::half>(q, ctx, GGML_TYPE_F16, 64, 5, 7);
    failed += check<sycl::half>(q, ctx, GGML_TYPE_F16, 128, 9, 13);
    printf("checks: 4, failed: %d\n", failed);
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
