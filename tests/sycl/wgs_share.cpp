// Work-group local storage shared between work-items, as ggml-sycl's flash-attention kernel uses it: work-item 0 writes a
// buffer declared with syclex::work_group_static, the group barriers, and work-item 1 reads the values back through the
// same buffer. The value written by item 0 must be read by item 1. Expected output: "wgs_share ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/work_group_static.hpp>
#include <cstdio>

namespace syclex = sycl::ext::oneapi::experimental;

int main() {
    sycl::queue q;
    float * out = sycl::malloc_shared<float>(2, q);
    out[0] = out[1] = -1.0f;
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(2), sycl::range<1>(2)), [=](sycl::nd_item<1> it) {
        syclex::work_group_static<float[2]> lsm;
        float * shared = (float *) &lsm;
        const int lid = (int) it.get_local_id(0);
        if (lid == 0) {
            shared[0] = 3.0f;
            shared[1] = 5.0f;
        }
        sycl::group_barrier(it.get_group());
        out[lid] = shared[0] + shared[1] * (lid == 1 ? 1.0f : 0.0f);
    }).wait();
    int bad = 0;
    if (out[1] != 8.0f) {
        std::printf("item 1 read %g, want 8 (3 + 5)\n", (double) out[1]);
        bad++;
    }
    std::printf(bad ? "wgs_share FAIL %d\n" : "wgs_share ok\n", bad);
    return bad != 0;
}
