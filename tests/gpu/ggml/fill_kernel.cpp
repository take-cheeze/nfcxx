// The F32 path of ggml-sycl's fill op (ggml/src/ggml-sycl/fill.cpp), extracted verbatim from its kernel and its
// nd_range launch, with a host main in place of ggml_sycl_op_fill (which needs the whole backend context). The kernel
// and launch lines are copied unchanged; the host side uses USM and checks every element against the fill value.
// This is the oracle for the SYCL front end: it must run on the XPU and match, as the op does under test-backend-ops.
// Build: icpx -fsycl fill_kernel.cpp -o fill_kernel && ./fill_kernel
#include <sycl/sycl.hpp>
#include <cstdint>
#include <cstdio>

#define SYCL_FILL_BLOCK_SIZE 256

template <typename T>
static void fill_kernel(T * dst, const int64_t k, const T value,
                        const sycl::nd_item<1> & item) {
    const int64_t i = (int64_t)item.get_global_id(0);
    if (i >= k) {
        return;
    }
    dst[i] = value;
}

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    const int64_t k = 303 * 207 * 11 * 3;               // the test_fill shape in tests/test-backend-ops.cpp
    const int64_t num_blocks = (k + SYCL_FILL_BLOCK_SIZE - 1) / SYCL_FILL_BLOCK_SIZE;
    const float value = 2.0f;
    float * dst = sycl::malloc_shared<float>(k + 64, q);
    for (int64_t i = 0; i < k + 64; i++) dst[i] = -7.0f;  // guard tail past k must stay untouched
    void * dst_d = dst;

    // ggml_sycl_op_fill, F32 case: launch and kernel as in fill.cpp
    q.parallel_for(
        sycl::nd_range<1>(num_blocks * SYCL_FILL_BLOCK_SIZE, SYCL_FILL_BLOCK_SIZE),
        [=](sycl::nd_item<1> item) {
            fill_kernel(static_cast<float *>(dst_d), k, value, item);
        }).wait();

    int64_t bad = 0, guard = 0;
    for (int64_t i = 0; i < k; i++) bad += dst[i] != value;
    for (int64_t i = k; i < k + 64; i++) guard += dst[i] != -7.0f;
    printf("mismatches: %lld of %lld, guard writes: %lld of 64\n", (long long)bad, (long long)k, (long long)guard);
    sycl::free(dst, q);
    return bad != 0 || guard != 0;
}
