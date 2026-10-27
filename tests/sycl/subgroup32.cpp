// A kernel with [[sycl::reqd_sub_group_size(32)]] runs with 32-lane sub-groups (ggml-sycl's flash-attention tile kernels ask
// for 32), next to a kernel of the default 16 lanes: the sub-group's range, an xor butterfly over all its lanes (the mask 16
// step included), reduce_over_group, any_of_group and select_from_group must see the whole sub-group. The size comes from a
// template argument, as in ggml (the front end evaluates the attribute in the instance). Expected output: "subgroup32 ok".
#include <sycl/sycl.hpp>
#include <cstdio>

template <int W> static void run(sycl::queue &q, unsigned *out) {
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(64), sycl::range<1>(64)), [=](sycl::nd_item<1> it) [[sycl::reqd_sub_group_size(W)]] {
        sycl::sub_group sg = it.get_sub_group();
        const unsigned lane = (unsigned)sg.get_local_linear_id();
        unsigned x = lane;
        for (unsigned m = W / 2; m > 0; m >>= 1) x += sycl::permute_group_by_xor(sg, x, m);
        const unsigned r = sycl::reduce_over_group(sg, lane, sycl::plus<unsigned>());
        const bool any = sycl::any_of_group(sg, lane == W - 1);
        const unsigned last = sycl::select_from_group(sg, lane, sycl::id<1>(W - 1));
        const size_t g = it.get_global_id(0);
        out[g * 5 + 0] = (unsigned)sg.get_local_linear_range();
        out[g * 5 + 1] = x;
        out[g * 5 + 2] = r;
        out[g * 5 + 3] = any ? 1u : 0u;
        out[g * 5 + 4] = last;
    }).wait();
}

template <int W> static int check(const unsigned *out) {
    const unsigned sum = W * (W - 1) / 2;
    int bad = 0;
    for (int g = 0; g < 64; g++) {
        const unsigned want[5] = {(unsigned)W, sum, sum, 1u, (unsigned)W - 1};
        for (int k = 0; k < 5; k++)
            if (out[g * 5 + k] != want[k]) {
                if (bad < 4) std::printf("W=%d item %d value %d: %u, want %u\n", W, g, k, out[g * 5 + k], want[k]);
                bad++;
            }
    }
    return bad;
}

int main() {
    sycl::queue q;
    unsigned *out = sycl::malloc_shared<unsigned>(64 * 5, q);
    run<32>(q, out);
    int bad = check<32>(out);
    run<16>(q, out);
    bad += check<16>(out);
    std::printf(bad ? "subgroup32 FAIL %d\n" : "subgroup32 ok\n", bad);
    return bad != 0;
}
