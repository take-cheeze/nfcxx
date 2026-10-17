// The F32 rms_norm of ggml-sycl (ggml/src/ggml-sycl/norm.cpp): out[i] = x[i] / sqrt(mean(x^2) + eps) over each row, the
// row being ne0 (the reduced dimension). The kernel rms_norm_f32 (the do_multiply = false, do_add = false instance: the
// plain op, ggml_sycl_op_rms_norm), the warp_reduce_sum it calls (common.hpp), its launch rms_norm_f32_sycl (the ncols < 1024
// branch, where one sub-group of WARP_SIZE work-items reduces a row), and ggml_sycl_op_rms_norm's stride setup are copied
// from those files. Replaced: the backend context (ggml_backend_sycl_context, ctx.stream(), ggml_sycl_set_device and
// ggml_sycl_info) by a sycl::queue and a host main; calculate_offset is copied from common.hpp, and the dpct helper
// permute_sub_group_by_xor is copied from ggml-sycl's dpct/helper.hpp. The
// fused do_multiply / do_add instances and the l2_norm, group_norm and rms_norm_back kernels are not part of this oracle.
// WARP_SIZE is 16 (the Intel build default of ggml-sycl's CMakeLists.txt). The host side: a double-precision reference,
// rows of mixed magnitude (so eps matters: a row of zeros and a row of 1e-3 values), and 64 guard slots past the output.
// Build: scripts/sycl-build.sh --backend=opencl rms_norm_kernel.cpp -o rms_norm_kernel && ./rms_norm_kernel
#include <sycl/sycl.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#define __dpct_inline__ inline
#define WARP_SIZE 16

// ---- dpct helper (ggml-sycl's dpct/helper.hpp, permute_sub_group_by_xor) ----

namespace dpct {
template <typename T>
T permute_sub_group_by_xor(sycl::sub_group g, T x, unsigned int mask, unsigned int logical_sub_group_size = 32) {
    unsigned int id = g.get_local_linear_id();
    unsigned int start_index = id / logical_sub_group_size * logical_sub_group_size;
    unsigned int target_offset = (id % logical_sub_group_size) ^ mask;
    return sycl::select_from_group(g, x, sycl::id<1>(start_index + target_offset));
}
}  // namespace dpct

// ---- common.hpp: calculate_offset, ceil_div ----

template <int N>
static __dpct_inline__ size_t calculate_offset(const std::array<int64_t, N> & strides, const std::array<int, N> & indices) {
    size_t offset = 0;
    for (int i = 0; i < N; i++) {
        offset += strides[i] * indices[i];
    }
    return offset;
}

static size_t ceil_div(const size_t m, const size_t n) {
    return (m + n - 1) / n;
}

// ---- common.hpp: warp_reduce_sum(float, nd_item) ----

static __dpct_inline__ float warp_reduce_sum(float x, const sycl::nd_item<3> & item_ct1) {
#pragma unroll
    for (int mask = WARP_SIZE / 2; mask > 0; mask >>= 1) {
        x += dpct::permute_sub_group_by_xor(item_ct1.get_sub_group(), x, mask);
    }
    return x;
}

// ---- norm.cpp: rms_norm_f32 (do_multiply = do_add = false) ----

static void rms_norm_f32(const float * x, float * dst, const int ncols,
    const int64_t src_stride_col, const int64_t src_stride_row, const int64_t src_stride_channel, const int64_t src_stride_sample,
    const int64_t dst_stride_col, const int64_t dst_stride_row, const int64_t dst_stride_channel, const int64_t dst_stride_sample,
    const float eps, const sycl::nd_item<3> & item_ct1, float * s_sum, int block_size) {

    const int sample  = item_ct1.get_group(0);
    const int channel = item_ct1.get_group(1);
    const int row     = item_ct1.get_group(2);

    const int nthreads = item_ct1.get_local_range(2);

    const int tid = item_ct1.get_local_id(2);
    const int nwarps = nthreads / WARP_SIZE;

    const auto src_offset = calculate_offset<3>({src_stride_sample, src_stride_channel, src_stride_row}, {sample, channel, row});
    const auto dst_offset = calculate_offset<3>({dst_stride_sample, dst_stride_channel, dst_stride_row}, {sample, channel, row});

    x   += src_offset;
    dst += dst_offset;

    float tmp = 0.0f; // partial sum for thread in warp

    for (int col = tid; col < ncols; col += block_size) {
        const float xi = x[col * src_stride_col];
        tmp += xi * xi;
    }

    // sum up partial sums
    tmp = warp_reduce_sum(tmp, item_ct1);
    if (block_size > WARP_SIZE) {
        const auto sub_group = item_ct1.get_sub_group();
        const auto sg_id = sub_group.get_group_linear_id();
        const auto wi_in_sg = sub_group.get_local_linear_id();
        if (wi_in_sg == 0) {
            s_sum[sg_id] = tmp;
        }

        item_ct1.barrier(sycl::access::fence_space::local_space);
        const size_t nreduce = ceil_div(nwarps, WARP_SIZE);
        tmp = 0.f;
        for (size_t i = 0; i < nreduce; i += 1)
        {
            tmp += s_sum[wi_in_sg + i * WARP_SIZE];
        }
        tmp = warp_reduce_sum(tmp, item_ct1);
    }

    const float mean = tmp / ncols;
    const float scale = sycl::rsqrt(mean + eps);

    for (int col = tid; col < ncols; col += block_size) {
        // the explicit temporary keeps the float evaluation order of ggml's fused-scale instance (scale_mul = 1 here)
        const float v = scale * x[col * src_stride_col];
        dst[col * dst_stride_col] = v * 1.0f;
    }
}

// ---- norm.cpp: rms_norm_f32_sycl, the ncols < 1024 branch (one sub-group of WARP_SIZE work-items per row) ----

static void rms_norm_f32_sycl(sycl::queue * stream, const float * x, float * dst, const int ncols, const int nrows,
    const int nchannels, const int nsamples,
    const int64_t src_stride_col, const int64_t src_stride_row, const int64_t src_stride_channel, const int64_t src_stride_sample,
    const int64_t dst_stride_col, const int64_t dst_stride_row, const int64_t dst_stride_channel, const int64_t dst_stride_sample,
    const float eps) {
    const sycl::range<3> global_dims(nsamples, nchannels, nrows);
    const sycl::range<3> block_dims(1, 1, WARP_SIZE);
    stream->submit([&](sycl::handler & cgh) {
        cgh.parallel_for(
            sycl::nd_range<3>(global_dims * block_dims, block_dims),
            [=](sycl::nd_item<3> item_ct1) [[sycl::reqd_sub_group_size(WARP_SIZE)]] {
                rms_norm_f32(x, dst, ncols,
                    src_stride_col, src_stride_row, src_stride_channel, src_stride_sample,
                    dst_stride_col, dst_stride_row, dst_stride_channel, dst_stride_sample,
                    eps, item_ct1, nullptr, WARP_SIZE);
            });
    });
}

// ---- norm.cpp: ggml_sycl_op_rms_norm's stride setup (the tensor's ne and nb, F32, contiguous rows) ----

static void rms_norm_launch(sycl::queue * stream, const float * src, float * dst, const int64_t ne[4], float eps) {
    const int64_t ss0 = 1, ss1 = ne[0], ss2 = ne[0] * ne[1], ss3 = ne[0] * ne[1] * ne[2];
    const int64_t ds0 = 1, ds1 = ne[0], ds2 = ne[0] * ne[1], ds3 = ne[0] * ne[1] * ne[2];
    rms_norm_f32_sycl(stream, src, dst, (int) ne[0], (int) ne[1], (int) ne[2], (int) ne[3],
        ss0, ss1, ss2, ss3, ds0, ds1, ds2, ds3, eps);
}

// ---- host side ----

static const float EPS = 1e-6f;

// The input values: a fixed LCG, so the run is repeatable. Row r has amplitude amp(r): mostly O(1) values, every fifth row
// 1e-3 (mean square ~3e-7, where eps is a third of the denominator), and every seventh row all zeros (eps alone keeps the
// division finite; without it 0/0 is NaN).
static uint32_t lcg(uint32_t & state) {
    state = state * 1664525u + 1013904223u;
    return state;
}

static float next_value(uint32_t & state, double amp) {
    const float u = (float) ((lcg(state) >> 8) & 0xFFFFFF) / (float) 0x1000000;  // [0, 1)
    return (float) ((2.0 * u - 1.0) * amp);
}

static double row_amp(int64_t row) {
    if (row % 7 == 3) return 0.0;
    if (row % 5 == 2) return 1e-3;
    return 4.0;
}

// One check: rms_norm over an ne shape (ne0 is the reduced dimension). Prints one verdict line.
static int check(sycl::queue & q, const int64_t ne[4], uint32_t seed) {
    const int64_t n = ne[0] * ne[1] * ne[2] * ne[3];
    const int64_t nrows = ne[1] * ne[2] * ne[3];

    float * src = sycl::malloc_shared<float>(n, q);
    float * dst = sycl::malloc_shared<float>(n + 64, q);
    uint32_t state = seed;
    for (int64_t r = 0; r < nrows; r++) {
        const double amp = row_amp(r);
        for (int64_t c = 0; c < ne[0]; c++) src[r * ne[0] + c] = next_value(state, amp);
    }
    for (int64_t i = 0; i < n + 64; i++) dst[i] = -7.0f;  // guard tail past n must stay untouched

    rms_norm_launch(&q, src, dst, ne, EPS);
    q.wait();

    int64_t bad = 0, guard = 0;
    double worst = 0.0;
    for (int64_t r = 0; r < nrows; r++) {
        double sum2 = 0.0;
        for (int64_t c = 0; c < ne[0]; c++) {
            const double x = (double) src[r * ne[0] + c];
            sum2 += x * x;
        }
        const double scale = 1.0 / std::sqrt(sum2 / (double) ne[0] + (double) EPS);
        for (int64_t c = 0; c < ne[0]; c++) {
            const int64_t i = r * ne[0] + c;
            const double want = (double) src[i] * scale;
            const double got  = (double) dst[i];
            const double err  = std::fabs(got - want);
            const double tol  = 1e-5 * std::max(1.0, std::fabs(want));
            if (!(err <= tol)) bad++;  // NaN fails too
            if (!std::isnan(err) && err > worst) worst = err;
        }
    }
    for (int64_t i = n; i < n + 64; i++) guard += dst[i] != -7.0f;

    const bool ok = bad == 0 && guard == 0;
    printf("rms_norm %lldx%lldx%lldx%lld: mismatches: %lld of %lld, guard writes: %lld of 64, max abs err %.3g: %s\n",
           (long long) ne[0], (long long) ne[1], (long long) ne[2], (long long) ne[3],
           (long long) bad, (long long) n, (long long) guard, worst, ok ? "ok" : "FAIL");
    sycl::free(src, q);
    sycl::free(dst, q);
    return ok ? 0 : 1;
}

static int run_all(sycl::queue & q) {
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    const int64_t shapes[2][4] = { { 64, 4, 2, 1 }, { 128, 7, 3, 2 } };
    int failed = 0, total = 0;
    for (int s = 0; s < 2; s++) {
        failed += check(q, shapes[s], 4242u + 17u * s);
        total++;
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
