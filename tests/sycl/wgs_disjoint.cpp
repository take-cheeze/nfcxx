// Work-group statics of kernels that never run together share local memory, as ggml-sycl's fattn-tile instances need: each
// of the six kernels below declares a 48 KB syclex::work_group_static, 288 KB in all, more local memory than a work-group
// gets (128 KB on an Arc B60). Each kernel alone fits, so each must build and launch, and share its values through its buffer:
// work-item 0 writes, the group barriers, work-item 1 reads. Expected output: "wgs_disjoint ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/work_group_static.hpp>
#include <cstdio>

namespace syclex = sycl::ext::oneapi::experimental;

template <int K> struct tag;

template <int K> float run(sycl::queue &q, float *out) {
    constexpr int n = 48 * 1024 / sizeof(float);
    q.parallel_for<tag<K>>(sycl::nd_range<1>(sycl::range<1>(2), sycl::range<1>(2)), [=](sycl::nd_item<1> it) {
        syclex::work_group_static<float[n]> lsm;
        float *shared = (float *) &lsm;
        const int lid = (int) it.get_local_id(0);
        if (lid == 0) {
            shared[0] = (float) K;
            shared[n - 1] = 10.0f * K;
        }
        sycl::group_barrier(it.get_group());
        if (lid == 1) out[0] = shared[0] + shared[n - 1];
    }).wait();
    return out[0];
}

int main() {
    sycl::queue q;
    float *out = sycl::malloc_shared<float>(1, q);
    const float got[6] = {run<1>(q, out), run<2>(q, out), run<3>(q, out), run<4>(q, out), run<5>(q, out), run<6>(q, out)};
    int bad = 0;
    for (int k = 1; k <= 6; k++) {
        if (got[k - 1] != 11.0f * k) {
            std::printf("kernel %d: item 1 read %g, want %g\n", k, (double) got[k - 1], 11.0 * k);
            bad++;
        }
    }
    std::printf(bad ? "wgs_disjoint FAIL %d\n" : "wgs_disjoint ok\n", bad);
    return bad != 0;
}
