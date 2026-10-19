// The softmax denominator of ggml-sycl's flash-attention vector kernel (fattn-vec.hpp, final section) for one key. A block of
// 16 x 8 work-items (lane = get_local_id(2), warp = get_local_id(1)). Only work-item (warp 0, lane 0) holds a weight of 1,
// as the single key of the decode case does; all others hold 0. The kernel zeroes KQ_sum_shared[0..15] from warp 0, reduces
// each warp over its 16 lanes, writes one total per warp, then every item reads KQ_sum_shared[lane], reduces it over 16 and
// keeps the result. Every item must end with exactly 1. Expected output: "fattn_denominator_single_key ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/work_group_static.hpp>
#include <cstdio>

namespace syclex = sycl::ext::oneapi::experimental;

// dpct::permute_sub_group_by_xor with a logical width (as dpct/helper.hpp defines it)
template <typename T>
static T permute_xor(sycl::sub_group g, T x, unsigned int mask, unsigned int logical) {
    unsigned int id = g.get_local_linear_id();
    unsigned int start_index = id / logical * logical;
    unsigned int target_offset = (id % logical) ^ mask;
    return sycl::select_from_group(g, x, target_offset < logical ? start_index + target_offset : id);
}

// warp_reduce_sum<16> of common.hpp
static float warp_reduce_sum16(float x, sycl::sub_group g) {
#pragma unroll
    for (int offset = 8; offset > 0; offset >>= 1) {
        x += permute_xor(g, x, offset, 16);
    }
    return x;
}

int main() {
    sycl::queue q;
    float * out = sycl::malloc_shared<float>(128, q);
    for (int i = 0; i < 128; i++) out[i] = -1.0f;
    q.parallel_for(sycl::nd_range<3>(sycl::range<3>(1, 8, 16), sycl::range<3>(1, 8, 16)), [=](sycl::nd_item<3> it) {
        syclex::work_group_static<float[16]> KQ_sum_shared;
        const int lane = (int) it.get_local_id(2);
        const int warp = (int) it.get_local_id(1);
        sycl::sub_group g = it.get_sub_group();

        // KQ_sum_shared[j*warp_size + lane] = 0 by warp 0
        if (warp == 0) {
            KQ_sum_shared[lane] = 0.0f;
        }
        sycl::group_barrier(it.get_group());

        // one key, held by (warp 0, lane 0)
        float KQ_sum = (warp == 0 && lane == 0) ? 1.0f : 0.0f;
        KQ_sum = warp_reduce_sum16(KQ_sum, g);
        if (lane == 0) {
            KQ_sum_shared[warp] = KQ_sum;
        }
        sycl::group_barrier(it.get_group());

        KQ_sum = KQ_sum_shared[lane];
        KQ_sum = warp_reduce_sum16(KQ_sum, g);
        out[warp * 16 + lane] = KQ_sum;
    }).wait();
    int bad = 0;
    for (int i = 0; i < 128; i++) {
        if (out[i] != 1.0f) {
            if (bad < 4) std::printf("item %d (warp %d lane %d): denominator %g want 1\n", i, i / 16, i % 16, (double) out[i]);
            bad++;
        }
    }
    std::printf(bad ? "fattn_denominator_single_key FAIL %d\n" : "fattn_denominator_single_key ok\n", bad);
    return bad != 0;
}
