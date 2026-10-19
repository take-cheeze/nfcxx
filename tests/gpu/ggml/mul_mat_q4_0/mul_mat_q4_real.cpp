// The real ggml-sycl dmmv.cpp (ggml/src/ggml-sycl/dmmv.cpp, unchanged), compiled as this program's own TU through the nfcxx
// SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first). The entry
// point is the real ggml_sycl_op_dequantize_mul_mat_vec, the function the ggml-sycl mul_mat dispatch reaches for a quantized
// src0 with F32 src1 and one column (can_use_dequantize_mul_mat_vec, no reorder, no quantized src1, no oneMKL or DNNL path).
// Its src0 is Q4_0 (dequantize_q4_0, the generic dequantize_mul_mat_vec<QK4_0, QR4_0, ...> instance, one sub-group per row
// with a xor-butterfly reduction). Q4_0 packs two 4-bit quants per byte: qs[j] holds element j in its low nibble and element
// j + 16 in its high nibble (QK4_0 / 2 = 16), and the kernel reads them as the x and y halves of one dfloat2. The src1 vector
// is converted to F16 inside the entry point (the GGML_SYCL_F16 build, as libggml-sycl.so was built), and the partial sums
// are F16 (sycl::half2).
//
// Oracle: the Q4_0 weights are quantized on the host (d = amax / 7 in F16, q = round(x / d) + 8 clamped to 0..15, packed as
// above); the reference unpacks the nibbles on the host and takes the double-precision dot product of the dequantized weights
// d * (q - 8) with src1 (rounded to F16 first when GGML_SYCL_F16 is set, as the entry point then converts it), and a per-row
// bound of tol_rel * sum_k |w_k x_k| (the error scales with the sum of magnitudes, not with the result). Without
// GGML_SYCL_F16 the kernel is the F32 one (F32 src1, float partial sums).
// Shapes: ncols 32 (the sub-group mask branch for ncols <= DMMV_X), 256 and 1024, rows 5, 64 and 37. 64 guard slots past the
// output must stay untouched.
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every symbol
// of the executable local), as in tests/gpu/ggml/rope/rope_real.cpp.
#include "dmmv.cpp"
// The F32 -> F16 conversion of src1 (ggml_get_to_fp16_sycl, the F16 build only), compiled from the upstream convert.cpp in
// this TU too: the to-fp16 kernels take a sycl::queue, and the libggml-sycl.so copy of them takes the oneAPI compiler's
// sycl::_V1::queue, so calling that copy from here crashes in its device check (see the pool note below).
#include "convert.cpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

// The scratch pool for the F16 path (ctx.pool() in ggml_sycl_op_dequantize_mul_mat_vec converts src1 into it). The real
// ggml_backend_sycl_context::new_pool_for_device (ggml-sycl.cpp) is in libggml-sycl.so, built by the oneAPI compiler, whose
// sycl::queue is sycl::_V1::queue; this TU's queue is the nfcxx subset's sycl::queue, so the call does not link to it. This
// is the harness's own pool, a device USM allocation per request, with the same ggml_sycl_pool interface (the kernel only
// needs scratch memory). It is used only when the F16 build calls pool(); the F32 build never does.
struct mm_test_pool : ggml_sycl_pool {
    sycl::queue * q;
    explicit mm_test_pool(sycl::queue * qp) : q(qp) {}
    void * alloc(size_t size, size_t * actual_size) override {
        *actual_size = size;
        return sycl::malloc_device(size, *q);
    }
    void free(void * ptr, size_t) override {
        q->wait();
        sycl::free(ptr, *q);
    }
};

std::unique_ptr<ggml_sycl_pool> ggml_backend_sycl_context::new_pool_for_device(queue_ptr qptr, int) {
    return std::make_unique<mm_test_pool>(qptr);
}

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float mm_next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

// One check: y = W x with W (nrows x ncols) Q4_0 and x F32 (ncols), run through the real entry point on the device.
static int mm_check(sycl::queue & q, ggml_backend_sycl_context & ctx, int64_t ncols, int64_t nrows, uint32_t seed,
                    const char * shape_name) {
#ifdef GGML_SYCL_F16
    const double tol_rel = 2e-2;   // half2 partial sums and the F16 src1
#else
    const double tol_rel = 1e-4;   // float partial sums
#endif
    const int64_t nblk = ncols / QK4_0;

    // host: the Q4_0 weights (blocks are row-major, nblk per row) and the F32 vector
    std::vector<block_q4_0> wh((size_t) (nrows * nblk));
    std::vector<float>      xh((size_t) ncols);
    uint32_t state = seed;
    std::vector<float> wf((size_t) (nrows * ncols));
    for (auto & v : wf) v = mm_next_value(state);
    for (auto & v : xh) v = mm_next_value(state);
    for (int64_t r = 0; r < nrows; r++) {
        for (int64_t b = 0; b < nblk; b++) {
            const float * src = &wf[(size_t) (r * ncols + b * QK4_0)];
            float amax = 0.0f;
            for (int j = 0; j < QK4_0; j++) amax = std::max(amax, std::fabs(src[j]));
            block_q4_0 & blk = wh[(size_t) (r * nblk + b)];
            blk.d = sycl::half(amax / 7.0f);  // ggml_half is sycl::half in this TU (ggml-common.h, GGML_COMMON_DECL_SYCL)
            const float id = amax > 0.0f ? 7.0f / amax : 0.0f;
            uint8_t q[QK4_0];
            for (int j = 0; j < QK4_0; j++) {
                int v = (int) std::lrintf(src[j] * id) + 8;
                q[j] = (uint8_t) std::min(15, std::max(0, v));
            }
            // the packing: element j in the low nibble of qs[j], element j + 16 in the high nibble
            for (int j = 0; j < QK4_0 / 2; j++) blk.qs[j] = (uint8_t) (q[j] | (q[j + QK4_0 / 2] << 4));
        }
    }

    // device buffers: src0 blocks, src1 F32, dst with 64 guard slots past the end
    block_q4_0 * w = sycl::malloc_shared<block_q4_0>(wh.size(), q);
    float *      x = sycl::malloc_shared<float>(ncols, q);
    float *      dst = sycl::malloc_shared<float>(nrows + 64, q);
    std::memcpy(w, wh.data(), wh.size() * sizeof(block_q4_0));
    std::memcpy(x, xh.data(), (size_t) ncols * sizeof(float));
    const float guard = -7.0f;
    for (int64_t i = 0; i < nrows + 64; i++) dst[i] = guard;

    // tensors: src0 is Q4_0 with no extra (no reorder), src1 F32 [ncols, 1], dst F32 [nrows, 1]
    ggml_tensor src0_t{};
    src0_t.type = GGML_TYPE_Q4_0;
    src0_t.ne[0] = ncols; src0_t.ne[1] = nrows; src0_t.ne[2] = 1; src0_t.ne[3] = 1;
    src0_t.nb[0] = sizeof(block_q4_0);
    src0_t.nb[1] = src0_t.nb[0] * nblk;
    src0_t.nb[2] = src0_t.nb[1] * nrows;
    src0_t.nb[3] = src0_t.nb[2];
    src0_t.data = w;

    ggml_tensor src1_t{};
    src1_t.type = GGML_TYPE_F32;
    src1_t.ne[0] = ncols; src1_t.ne[1] = 1; src1_t.ne[2] = 1; src1_t.ne[3] = 1;
    src1_t.nb[0] = sizeof(float);
    src1_t.nb[1] = src1_t.nb[0] * ncols;
    src1_t.nb[2] = src1_t.nb[1];
    src1_t.nb[3] = src1_t.nb[2];
    src1_t.data = x;

    ggml_tensor dst_t{};
    dst_t.type = GGML_TYPE_F32;
    dst_t.ne[0] = nrows; dst_t.ne[1] = 1; dst_t.ne[2] = 1; dst_t.ne[3] = 1;
    dst_t.nb[0] = sizeof(float);
    dst_t.nb[1] = dst_t.nb[0] * nrows;
    dst_t.nb[2] = dst_t.nb[1];
    dst_t.nb[3] = dst_t.nb[2];
    dst_t.data = dst;
    dst_t.src[0] = &src0_t;
    dst_t.src[1] = &src1_t;

    // the dispatch's call: the whole row range, no column split, no quantized src1
    ggml_sycl_op_dequantize_mul_mat_vec(ctx, &src0_t, &src1_t, &dst_t,
                                        (const char *) w, x, nullptr, dst, 0, nrows,
                                        1, 0, &q);
    q.wait();

    // reference: per row, the double-precision dot product of the dequantized weights with the F16-rounded src1; the
    // weights are unpacked from the nibbles here (element j = low nibble of qs[j], j + 16 = high nibble of qs[j])
    int64_t bad = 0, guard_w = 0;
    double  worst = 0.0;
    for (int64_t r = 0; r < nrows; r++) {
        double want = 0.0, sumabs = 0.0;
        for (int64_t b = 0; b < nblk; b++) {
            const block_q4_0 & blk = wh[(size_t) (r * nblk + b)];
            const double d = (double) (float) blk.d;
            for (int j = 0; j < QK4_0; j++) {
                const int nib = j < QK4_0 / 2 ? (blk.qs[j] & 0xF) : (blk.qs[j - QK4_0 / 2] >> 4);
#ifdef GGML_SYCL_F16
                const double xv = (double) (float) sycl::half(xh[(size_t) (b * QK4_0 + j)]);
#else
                const double xv = (double) xh[(size_t) (b * QK4_0 + j)];
#endif
                const double term = d * (double) (nib - 8) * xv;
                want += term;
                sumabs += std::fabs(term);
            }
        }
        const double got = (double) dst[r];
        const double err = std::fabs(got - want);
        const double tol = tol_rel * sumabs + 1e-6;
        if (!(err <= tol)) bad++;  // NaN fails too
        if (!std::isnan(err) && err / (sumabs + 1e-6) > worst) worst = err / (sumabs + 1e-6);
    }
    for (int64_t i = nrows; i < nrows + 64; i++) guard_w += dst[i] != guard;

    const bool ok = bad == 0 && guard_w == 0;
    printf("dmmv Q4_0 %s: mismatches: %lld of %lld, guard writes: %lld of 64, max err over sum|wx| %.3g: %s\n",
           shape_name, (long long) bad, (long long) nrows, (long long) guard_w, worst, ok ? "ok" : "FAIL");
    sycl::free(w, q);
    sycl::free(x, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

int main() {
    sycl::queue q;
    try {
        q = sycl::queue{sycl::gpu_selector_v};
    } catch (const sycl::exception & e) {
        printf("no GPU device: %s\n", e.what());
        return 70;
    }
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;

    const int64_t shapes[3][2] = { { 32, 5 }, { 256, 64 }, { 1024, 37 } };
    const char *  names[3]     = { "ncols 32 rows 5", "ncols 256 rows 64", "ncols 1024 rows 37" };
    int failed = 0, checks = 0;
    for (int s = 0; s < 3; s++) {
        failed += mm_check(q, ctx, shapes[s][0], shapes[s][1], 7001u + 31u * (uint32_t) s, names[s]) != 0;
        checks++;
    }
    printf("checks: %d, failed: %d\n", checks, failed);
    return failed != 0;
}
