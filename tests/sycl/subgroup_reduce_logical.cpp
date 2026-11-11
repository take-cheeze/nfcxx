// The xor-butterfly sum of ggml-sycl's warp_reduce_sum<width> (common.hpp) with a logical sub-group size: dpct's
// permute_sub_group_by_xor (dpct/helper.hpp) selects the lane start_index + ((id % width) ^ mask) with
// sycl::select_from_group. One work-group of 16 items: a single lane holds 1, the others 0. After the butterfly over
// width 16 every lane must hold 1 (the sum); after the butterfly over width 8 in each half of the sub-group, the half that
// holds the 1 must hold 1 and the other half 0. Expected output: "subgroup_reduce_logical ok".
#include <sycl/sycl.hpp>
#include <cstdio>

// dpct::permute_sub_group_by_xor, as dpct/helper.hpp defines it
template <typename T>
static T permute_xor(sycl::sub_group g, T x, unsigned int mask, unsigned int logical) {
    unsigned int id = g.get_local_linear_id();
    unsigned int start_index = id / logical * logical;
    unsigned int target_offset = (id % logical) ^ mask;
    return sycl::select_from_group(g, x, target_offset < logical ? start_index + target_offset : id);
}

template <int width>
static float warp_reduce_sum(float x, sycl::sub_group g) {
#pragma unroll
    for (int offset = width / 2; offset > 0; offset >>= 1) {
        x += permute_xor(g, x, offset, width);
    }
    return x;
}

int main() {
    sycl::queue q;
    float * out16 = sycl::malloc_shared<float>(16, q);
    float * out8 = sycl::malloc_shared<float>(16, q);
    for (int i = 0; i < 16; i++) { out16[i] = -1.0f; out8[i] = -1.0f; }
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(16), sycl::range<1>(16)), [=](sycl::nd_item<1> it) {
        sycl::sub_group g = it.get_sub_group();
        const int lane = (int) it.get_local_id(0);
        const float x = lane == 0 ? 1.0f : 0.0f;
        out16[lane] = warp_reduce_sum<16>(x, g);
        out8[lane] = warp_reduce_sum<8>(x, g);
    }).wait();
    int bad = 0;
    for (int i = 0; i < 16; i++) {
        if (out16[i] != 1.0f) { std::printf("width 16 lane %d: got %g want 1\n", i, (double) out16[i]); bad++; }
        const float want8 = i < 8 ? 1.0f : 0.0f;
        if (out8[i] != want8) { std::printf("width 8 lane %d: got %g want %g\n", i, (double) out8[i], (double) want8); bad++; }
    }
    std::printf(bad ? "subgroup_reduce_logical FAIL %d\n" : "subgroup_reduce_logical ok\n", bad);
    return bad != 0;
}
