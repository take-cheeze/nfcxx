// Both barrier kinds, as ggml-sycl's flash-attention kernel uses them: sycl::group_barrier(sub_group) between a write and a
// read inside one sub-group, and sycl::group_barrier(group) between a write and a read across sub-groups. One work-group of
// 64 items (four sub-groups of 16). Every item writes its id to a work-group static array; after the sub-group barrier it
// reads its mirror lane in its own sub-group, after the work-group barrier the same lane of the next sub-group. tests/sycl/
// run.sh also checks the OpenCL module: the sub-group barrier is OpControlBarrier with Subgroup execution and memory scope,
// the work-group barrier keeps Workgroup scope. Expected output: "sg_barrier_scope ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/work_group_static.hpp>
#include <cstdio>

namespace syclex = sycl::ext::oneapi::experimental;

int main() {
    sycl::queue q;
    int * in_sg = sycl::malloc_shared<int>(64, q);
    int * across = sycl::malloc_shared<int>(64, q);
    for (int i = 0; i < 64; i++) { in_sg[i] = -1; across[i] = -1; }
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(64), sycl::range<1>(64)), [=](sycl::nd_item<1> it) {
        syclex::work_group_static<int[64]> S;
        const int i = (int) it.get_local_id(0);
        S[i] = 1000 + i;
        sycl::group_barrier(it.get_sub_group());
        in_sg[i] = S[(i & ~15) + (15 - (i & 15))];   // the mirror lane of this sub-group
        sycl::group_barrier(it.get_group());
        across[i] = S[(i + 16) % 64];                // the same lane of the next sub-group
    }).wait();
    int bad = 0;
    for (int i = 0; i < 64; i++) {
        const int want_sg = 1000 + (i & ~15) + (15 - (i & 15)), want_across = 1000 + (i + 16) % 64;
        if (in_sg[i] != want_sg || across[i] != want_across) {
            if (bad < 4) std::printf("item %d: in-sub-group %d (want %d), across %d (want %d)\n", i, in_sg[i], want_sg, across[i], want_across);
            bad++;
        }
    }
    std::printf(bad ? "sg_barrier_scope FAIL %d\n" : "sg_barrier_scope ok\n", bad);
    return bad != 0;
}
