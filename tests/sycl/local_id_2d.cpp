// The local ids of a 2-D work-group as ggml-sycl's flash-attention kernel uses them: a block of 16 x 8 work-items (dpct's
// block_dim (warp_size, nwarps, 1)) with get_local_id(2) the fast index (0..15) and get_local_id(1) the warp (0..7). Every
// work-item must see its own (id1, id2), and the 128 pairs must be distinct. Expected output: "local_id_2d ok".
#include <sycl/sycl.hpp>
#include <cstdio>

int main() {
    sycl::queue q;
    int * ids = sycl::malloc_shared<int>(128 * 2, q);
    for (int i = 0; i < 256; i++) ids[i] = -1;
    q.parallel_for(sycl::nd_range<3>(sycl::range<3>(1, 8, 16), sycl::range<3>(1, 8, 16)), [=](sycl::nd_item<3> it) {
        // stored at the item's global position (the group is the whole range), next to its local ids
        const int g = (int) (it.get_global_id(1) * 16 + it.get_global_id(2));
        ids[2 * g] = (int) it.get_local_id(1);
        ids[2 * g + 1] = (int) it.get_local_id(2);
    }).wait();
    int bad = 0;
    for (int g = 0; g < 128; g++) {
        if (ids[2 * g] != g / 16 || ids[2 * g + 1] != g % 16) {
            if (bad < 4) std::printf("item %d: local id1 %d id2 %d\n", g, ids[2 * g], ids[2 * g + 1]);
            bad++;
        }
    }
    std::printf(bad ? "local_id_2d FAIL %d\n" : "local_id_2d ok\n", bad);
    return bad != 0;
}
