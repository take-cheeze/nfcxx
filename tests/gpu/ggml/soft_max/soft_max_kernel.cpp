// The F32 soft_max of ggml-sycl (ggml/src/ggml-sycl/softmax.cpp): the row kernel soft_max_f32 (the max and the sum of each
// row by a work-group reduction: warp reductions over the sub-group, and, for a work-group of more than one sub-group, the
// partial results exchanged through local memory with barriers), its template fold over the column counts, and the
// launch in soft_max_f32_sycl / ggml_sycl_op_soft_max. The kernel bodies, the reductions (warp_reduce_max, warp_reduce_sum,
// from common.hpp) and get_alibi_slope are copied from the source; the launch takes a sycl::queue and the tensor fields
// as plain values instead of ggml_tensor and ggml_backend_sycl_context. Replaced: the ggml tensor and context (the op's
// fields are the launch's parameters), scope_op_debug_print, dpct::queue_ptr / dpct::dim3 (a sycl::queue * and a
// sycl::range<3>; dpct::dim3 (x, y, z) is the range<3> (z, y, x), so block_nums (ne01, ne02, ne03) becomes range<3>(ne03,
// ne02, ne01) and block_dims (nth, 1, 1) becomes range<3>(1, 1, nth), as in the source), ggml_sycl_info()'s limits (the
// device's work-group size and local memory, read from the queue's device), GGML_PAD, GGML_UNUSED, and the F16 mask arm
// (the mask is F32; sinks are absent). dpct::permute_sub_group_by_xor is the four-argument form of the sub-group xor
// exchange, defined here over the nfcxx sycl::permute_group_by_xor. The host side is a main in the style of
// unary_kernel.cpp: USM, a double-precision reference and 64 guard slots past the output.
// Build: scripts/sycl-build.sh --backend=opencl soft_max_kernel.cpp -o soft_max_kernel && ./soft_max_kernel
#include <sycl/sycl.hpp>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <type_traits>
#include <utility>

#define __dpct_inline__ inline
#define WARP_SIZE 16  // the Intel build default of ggml-sycl's CMakeLists.txt
#define GGML_UNUSED(x) (void)(x)
#define GGML_PAD(x, n) (((x) + (n) - 1) & ~((n) - 1))

// dpct's sub-group xor exchange with a width (the form common.hpp uses); over the nfcxx sub-group the width is the sub-group size.
namespace dpct {
template <typename T>
static __dpct_inline__ T permute_sub_group_by_xor(sycl::sub_group sg, T x, unsigned int mask, int width) {
    (void) width;
    return sycl::permute_group_by_xor(sg, x, mask);
}
}  // namespace dpct

// ---- common.hpp: the warp reductions and the ALiBi slope ----

template <int width = WARP_SIZE>
static __dpct_inline__ float warp_reduce_max(float x) {
#pragma unroll
  for (int offset = width / 2; offset > 0; offset >>= 1) {
    x = sycl::fmax(x, dpct::permute_sub_group_by_xor(
                          sycl::ext::oneapi::this_work_item::get_sub_group(), x,
                          offset, width));
  }
  return x;
}

template <int width = WARP_SIZE>
static __dpct_inline__ float warp_reduce_sum(float x) {
#pragma unroll
  for (int offset = width / 2; offset > 0; offset >>= 1) {
    x += dpct::permute_sub_group_by_xor(
        sycl::ext::oneapi::this_work_item::get_sub_group(), x, offset, width);
  }
  return x;
}

static __dpct_inline__ float get_alibi_slope(const float    max_bias,
                                             const uint32_t h,
                                             const uint32_t n_head_log2,
                                             const float    m0,
                                             const float    m1) {
    if (max_bias <= 0.0f) {
        return 1.0f;
    }
    const float base = h < n_head_log2 ? m0 : m1;
    const int   exph = h < n_head_log2 ? h + 1 : 2*(h - n_head_log2) + 1;

    return sycl::pow(base, (float) exph);
}

// ---- softmax.cpp: the kernel ----

template <typename T> static __dpct_inline__ float t2f32(T val) {
    return (float) val;
}

struct soft_max_params {

    int64_t nheads;
    uint32_t n_head_log2;
    int64_t ncols;
    int64_t nrows_x;
    int64_t nrows_y;
    int64_t ne00;
    int64_t ne01;
    int64_t ne02;
    int64_t ne03;
    int64_t nb11;
    int64_t nb12;
    int64_t nb13;

    int64_t ne12;
    int64_t ne13;
    float scale;
    float max_bias;
    float m0;
    float m1;
};

// When ncols_template == 0 the bounds for the loops in this function are not known and can't be unrolled.
// As we want to keep pragma unroll for all other cases we suppress the clang transformation warning here.
#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpass-failed"
#endif // __clang__
template <bool use_shared, int ncols_template, int block_size_template, typename T>
static void soft_max_f32(const float *         x,
                         const T *             mask,
                         const float *         sinks,
                         float *               dst,
                         const soft_max_params p,
                         uint8_t *             dpct_local) {
    auto      item_ct1 = sycl::ext::oneapi::this_work_item::get_nd_item<3>();
    const int ncols    = ncols_template == 0 ? p.ncols : ncols_template;
    const int block_size = block_size_template == 0
                               ? item_ct1.get_local_range(2)
                               : block_size_template;
    const int nthreads = block_size;
    const int nwarps = nthreads / WARP_SIZE;
    const size_t nreduce = nwarps / WARP_SIZE;

    const int tid = item_ct1.get_local_id(2);

    const int64_t i03 = item_ct1.get_group(0);
    const int64_t i02 = item_ct1.get_group(1);
    const int64_t i01 = item_ct1.get_group(2);

    //TODO: noncontigous inputs/outputs
    const int rowx = item_ct1.get_group(2) +
                     item_ct1.get_group(1) * item_ct1.get_group_range(2) +
                     item_ct1.get_group(0) * item_ct1.get_group_range(2) *
                         item_ct1.get_group_range(1);

    const int64_t i11 = i01;
    const int64_t i12 = i02 % p.ne12;
    const int64_t i13 = i03 % p.ne13;

    x    += int64_t(rowx)*ncols;
    mask += (i11*p.nb11 + i12*p.nb12 + i13*p.nb13) / sizeof(T) * (mask != nullptr);
    dst  += int64_t(rowx)*ncols;

    const int warp_id = item_ct1.get_local_id(2) / WARP_SIZE;
    const int lane_id = item_ct1.get_local_id(2) % WARP_SIZE;

    const float slope = get_alibi_slope(p.max_bias, i02, p.n_head_log2, p.m0, p.m1);

    float * buf_iw = (float *) dpct_local;

    // shared memory buffer to cache values between iterations:
    float *vals = use_shared ? buf_iw + sycl::max(nwarps, WARP_SIZE) : dst;
    float max_val = sinks ? sinks[i02] : -INFINITY;
#pragma unroll
    for (int col0 = 0; col0 < ncols; col0 += block_size) {
        const int col = col0 + tid;

        if (ncols_template == 0 && col >= ncols) {
            break;
        }

        const float val = x[col]*p.scale + (mask ? slope*t2f32(mask[col]) : 0.0f);

        vals[col] = val;
        max_val   = sycl::max(max_val, val);
    }
    // find the max value in the block
    max_val = warp_reduce_max<WARP_SIZE>(max_val);

    if (block_size > WARP_SIZE) {
        if (lane_id == 0) {
            buf_iw[warp_id] = max_val;
        }
        item_ct1.barrier();

        max_val = -INFINITY;
        for (int i = lane_id; i < nwarps; i += WARP_SIZE) {
            max_val = sycl::max(max_val, buf_iw[i]);
        }
        max_val = warp_reduce_max<WARP_SIZE>(max_val);
    }
    float tmp = 0.0f; // partial sum

#pragma unroll
    for (int col0 = 0; col0 < ncols; col0 += block_size) {
        const int col = col0 + tid;

        if (ncols_template == 0 && col >= ncols) {
            break;
        }

        const float val = sycl::native::exp(sycl::max(vals[col] - max_val, -80.0f));
        tmp += val;
        vals[col] = val;
    }
    // find the sum of exps in the block
    tmp = warp_reduce_sum<WARP_SIZE>(tmp);
    if (block_size > WARP_SIZE) {
        item_ct1.barrier();
        if (warp_id == 0) {
            buf_iw[lane_id] = 0.0f;
            for (size_t i = 1; i < nreduce; i += 1) {
                buf_iw[lane_id + i * WARP_SIZE] = 0.f;
            }
        }
        item_ct1.barrier();

        if (lane_id == 0) {
            buf_iw[warp_id] = tmp;
        }
        item_ct1.barrier();

        tmp = buf_iw[lane_id];
        for (size_t i = 1; i < nreduce; i += 1) {
            tmp += buf_iw[lane_id + i * WARP_SIZE];
        }
        tmp = warp_reduce_sum<WARP_SIZE>(tmp);
    }
    if (sinks) {
        tmp += sycl::native::exp(sycl::max(sinks[i02] - max_val, -80.0f));
    }
    const float inv_sum = 1.0f / tmp;

#pragma unroll
    for (int col0 = 0; col0 < ncols; col0 += block_size) {
        const int col = col0 + tid;

        if (ncols_template == 0 && col >= ncols) {
            return;
        }

        dst[col] = vals[col] * inv_sum;
    }
}
#ifdef __clang__
#pragma clang diagnostic pop
#endif // __clang__

// ---- softmax.cpp: the launch ----

// The source's dpct::queue_ptr and dpct::dim3 are a sycl::queue * and a sycl::range<3> here (see the header).
template <int... Ns, typename T>
static void launch_soft_max_kernels(const float *           x,
                                    const T *               mask,
                                    const float *           sinks,
                                    float *                 dst,
                                    const soft_max_params & p,
                                    sycl::queue *          stream,
                                    sycl::range<3>         block_dims,
                                    sycl::range<3>         block_nums,
                                    size_t                  nbytes_shared)
{
    auto launch_kernel = [=](auto I) -> bool {
        constexpr int ncols = decltype(I)::value;
        constexpr int block = (ncols > 1024 ? 1024 : ncols);
        if (p.ncols == ncols) {
            stream->submit([&](sycl::handler &cgh) {
                sycl::local_accessor<uint8_t, 1> dpct_local_acc_ct1(
                    sycl::range<1>(nbytes_shared), cgh);

                cgh.parallel_for(
                    sycl::nd_range<3>(block_nums * block_dims, block_dims),
                    [=](sycl::nd_item<3> item_ct1) [[sycl::reqd_sub_group_size(
                        WARP_SIZE)]] {
                        soft_max_f32<true, ncols, block>(
                            x, mask, sinks, dst, p,
                            dpct_local_acc_ct1
                                .get_multi_ptr<sycl::access::decorated::no>()
                                .get());
                        GGML_UNUSED(item_ct1);
                    });
            });
            return true;
        }
        return false;
    };

    // unary fold over launch_kernel
    if ((launch_kernel(std::integral_constant<int, Ns>{}) || ...)) {
        return;
    }

    stream->submit([&](sycl::handler &cgh) {
        sycl::local_accessor<uint8_t, 1> dpct_local_acc_ct1(
            sycl::range<1>(nbytes_shared), cgh);

        cgh.parallel_for(
            sycl::nd_range<3>(block_nums * block_dims, block_dims),
            [=](sycl::nd_item<3> item_ct1)
                [[sycl::reqd_sub_group_size(WARP_SIZE)]] {
                    soft_max_f32<true, 0, 0>(
                        x, mask, sinks, dst, p,
                        dpct_local_acc_ct1
                            .get_multi_ptr<sycl::access::decorated::no>()
                            .get());
                    GGML_UNUSED(item_ct1);
                });
    });
}

// max_block_size and smpbo are ggml_sycl_info().max_work_group_sizes[device] and .devices[id].smpbo in the source.
template <typename T>
static void soft_max_f32_sycl(const float *x, const T *mask,
                              const float *sinks, float *dst,
                              const soft_max_params &params,
                              sycl::queue *stream, int max_block_size, size_t smpbo) {
    int nth = WARP_SIZE;
    const int64_t ncols_x = params.ncols;

    while (nth < ncols_x && nth < max_block_size) nth *= 2;
    if (nth>max_block_size) nth = max_block_size;

    const sycl::range<3> block_dims(1, 1, nth);
    const sycl::range<3> block_nums(params.ne03, params.ne02, params.ne01);
    const size_t nbytes_shared =
        (GGML_PAD(ncols_x, WARP_SIZE) + WARP_SIZE) * sizeof(float);

    if (nbytes_shared <= smpbo && ncols_x <= max_block_size) {
        launch_soft_max_kernels<32, 64, 128, 256, 512, 1024, 2048, 4096>(
            x, mask, sinks, dst, params, stream, block_dims, block_nums,
            nbytes_shared);
    } else {
        const size_t nbytes_shared_low = WARP_SIZE * sizeof(float);

        stream->submit([&](sycl::handler &cgh) {
            sycl::local_accessor<uint8_t, 1> dpct_local_acc_ct1(
                sycl::range<1>(nbytes_shared_low), cgh);

            cgh.parallel_for(
                sycl::nd_range<3>(block_nums * block_dims, block_dims),
                [=](sycl::nd_item<3> item_ct1)
                    [[sycl::reqd_sub_group_size(WARP_SIZE)]] {
                    soft_max_f32<false, 0, 0>(
                        x, mask, sinks, dst, params,
                        dpct_local_acc_ct1
                            .get_multi_ptr<sycl::access::decorated::no>()
                            .get());
                    GGML_UNUSED(item_ct1);
                });
        });
    }
}

// ggml_sycl_op_soft_max's body from the tensor fields: src0 is (ne00 x ne01 x ne02 x ne03) F32, the mask (when present) is
// F32 with ne01 rows per ne02 slice (mask_ne12 = ne02 or 1, mask_ne13 = 1 or ne03), dst the same shape as src0.
static void ggml_sycl_op_soft_max_fields(sycl::queue * stream, const float * src0_d, const float * mask_d,
                                         float * dst_d, int64_t ne00, int64_t ne01, int64_t ne02, int64_t ne03,
                                         int64_t mask_nb1, int64_t mask_nb2, int64_t mask_nb3,
                                         int64_t mask_ne2, int64_t mask_ne3, float scale, float max_bias,
                                         int max_block_size, size_t smpbo) {
    const int64_t nrows_x = ne01 * ne02 * ne03;
    const int64_t nrows_y = ne01;
    (void) nrows_x;

    const int64_t nb11 = mask_d ? mask_nb1 : 1;
    const int64_t nb12 = mask_d ? mask_nb2 : 1;
    const int64_t nb13 = mask_d ? mask_nb3 : 1;

    const int64_t ne12 = mask_d ? mask_ne2 : 1;
    const int64_t ne13 = mask_d ? mask_ne3 : 1;

    const uint32_t n_head      = (uint32_t) ne02;
    const uint32_t n_head_log2 = 1u << (uint32_t) floorf(log2f((float) n_head));

    const float m0 = powf(2.0f, -(max_bias       ) / n_head_log2);
    const float m1 = powf(2.0f, -(max_bias / 2.0f) / n_head_log2);

    soft_max_params params = {};
    params.nheads = ne02;
    params.n_head_log2 = n_head_log2;
    params.ncols = ne00;
    params.nrows_x = nrows_x;
    params.nrows_y = nrows_y;
    params.ne00 = ne00;
    params.ne01 = ne01;
    params.ne02 = ne02;
    params.ne03 = ne03;
    params.nb11 = nb11;
    params.nb12 = nb12;
    params.nb13 = nb13;
    params.ne12 = ne12;
    params.ne13 = ne13;
    params.scale = scale;
    params.max_bias = max_bias;
    params.m0 = m0;
    params.m1 = m1;

    soft_max_f32_sycl(src0_d, mask_d, (const float *) nullptr, dst_d, params, stream, max_block_size, smpbo);
}

// ---- host side ----

// The reference in double: softmax over each row of ne00 after scale and mask (no ALiBi: max_bias is 0, slope 1).
static void ref_row(const float * x, const float * mask, double scale, int64_t n, double * out) {
    double mx = -1e300;
    for (int64_t c = 0; c < n; c++) {
        const double v = (double) x[c] * scale + (mask ? (double) mask[c] : 0.0);
        out[c] = v;
        mx = std::max(mx, v);
    }
    double sum = 0.0;
    for (int64_t c = 0; c < n; c++) {
        out[c] = std::exp(out[c] - mx);
        sum += out[c];
    }
    for (int64_t c = 0; c < n; c++) out[c] /= sum;
}

// The input values: a fixed LCG over [-4, 4), so the run is repeatable.
static float next_value(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return (float) ((state >> 8) & 0xFFFFFF) / (float) 0x1000000 * 8.0f - 4.0f;
}

// One check: soft_max over ne (ne0 is the softmax dimension), with or without a mask of shape (ne0, ne1, ne2, 1) that
// broadcasts over ne3. mutant: the max is omitted (the run is expected to produce wrong results).
static int check(sycl::queue & q, const int64_t ne[4], bool masked, float scale, uint32_t seed, int max_block, size_t smpbo) {
    const int64_t n    = ne[0] * ne[1] * ne[2] * ne[3];
    const int64_t nrow = ne[1] * ne[2] * ne[3];

    float * src  = sycl::malloc_shared<float>(n, q);
    float * dst  = sycl::malloc_shared<float>(n + 64, q);
    float * mask = masked ? sycl::malloc_shared<float>(ne[0] * ne[1] * ne[2], q) : nullptr;
    uint32_t state = seed;
    for (int64_t i = 0; i < n; i++) src[i] = next_value(state);
    if (mask) for (int64_t i = 0; i < ne[0] * ne[1] * ne[2]; i++) mask[i] = next_value(state);
    for (int64_t i = 0; i < n + 64; i++) dst[i] = -7.0f;  // guard tail past n must stay untouched

    // the mask's byte strides: row (ne0 floats), slice (ne1 rows), and the broadcast over ne3 (stride 0 there)
    const int64_t mnb1 = ne[0] * (int64_t) sizeof(float);
    const int64_t mnb2 = mnb1 * ne[1];
    const int64_t mnb3 = mnb2 * ne[2];

    ggml_sycl_op_soft_max_fields(&q, src, mask, dst, ne[0], ne[1], ne[2], ne[3], mnb1, mnb2, mnb3,
                                 ne[2], 1, scale, 0.0f, max_block, smpbo);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    double * want = (double *) std::malloc(sizeof(double) * ne[0]);
    for (int64_t r = 0; r < nrow; r++) {
        // row r = i1 + i2*ne1 + i3*ne1*ne2 (the kernel's rowx); its mask row is i1 + i2*ne1 in the mask's slice of i2
        const int64_t i1 = r % ne[1];
        const int64_t i2 = (r / ne[1]) % ne[2];
        const float * x  = src + r * ne[0];
        const float * m  = mask ? mask + (i1 * ne[0] + i2 * ne[0] * ne[1]) : nullptr;
        ref_row(x, m, (double) scale, ne[0], want);
        for (int64_t c = 0; c < ne[0]; c++) {
            const double got = (double) dst[r * ne[0] + c];
            const double err = std::fabs(got - want[c]);
            const double tol = 1e-5 * std::fabs(want[c]) + 1e-30;  // relative to each output
            if (!(err <= tol)) bad++;  // NaN fails too
            if (!std::isnan(err) && want[c] != 0.0) {
                const double rel = err / std::fabs(want[c]);
                if (rel > worst) worst = rel;
            }
        }
    }
    std::free(want);
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("soft_max %lldx%lldx%lldx%lld %s scale %g: mismatches: %lld of %lld, guard writes: %lld of 64, max rel err %.3g: %s\n",
           (long long)ne[0], (long long)ne[1], (long long)ne[2], (long long)ne[3],
           masked ? "masked" : "no mask", (double) scale,
           (long long)bad, (long long)n, (long long)guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    if (mask) sycl::free(mask, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());
    const int max_block = (int) q.get_device().get_info<sycl::info::device::max_work_group_size>();
    const size_t smpbo  = (size_t) q.get_device().get_info<sycl::info::device::local_mem_size>();

    const int64_t shapes[2][4] = { { 64, 4, 2, 1 }, { 128, 7, 3, 2 } };
    int failed = 0, total = 0;
    for (int s = 0; s < 2; s++) {
        for (int masked = 0; masked < 2; masked++) {
            failed += check(q, shapes[s], masked != 0, 1.0f, 2024u + 17u * s + 5u * masked, max_block, smpbo);
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
