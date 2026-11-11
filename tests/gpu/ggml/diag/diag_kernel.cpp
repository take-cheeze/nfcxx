// The F32 path of ggml-sycl's diag op (ggml/src/ggml-sycl/diag.cpp), extracted verbatim from its kernel and its
// nd_range launch, with a host main in place of ggml_sycl_op_diag (which needs the whole backend context). The kernel
// and launch lines are copied unchanged; the host side uses USM and checks every output element against the diag
// definition: out[i, j] = (i == j ? src[j] : 0) per batch, with dst ne1 = ne0 and src shaped {ne0, 1, ne2, ne3}.
// Build: icpx -fsycl diag_kernel.cpp -o diag_kernel && ./diag_kernel 10 1 4 3
#include <sycl/sycl.hpp>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>

#define SYCL_DIAG_BLOCK_SIZE 256

template <typename T>
static void diag_kernel(T * __restrict__ dst, const T * __restrict__ src,
                        const int64_t ne0, const int64_t ne1,
                        const int64_t ne2, const int64_t ne3,
                        const int64_t total_elements,
                        const sycl::nd_item<1> & item) {
    const int64_t i = item.get_global_id(0);
    if (i >= total_elements) {
        return;
    }

    const int64_t i0 = i % ne0;
    const int64_t i1 = (i / ne0) % ne1;
    const int64_t i2 = (i / (ne0 * ne1)) % ne2;
    const int64_t i3 = i / (ne0 * ne1 * ne2);

    const int64_t dst_idx = ((i3 * ne2 + i2) * ne1 + i1) * ne0 + i0;

    if (i0 == i1) {
        const int64_t batch_idx = i3 * ne2 + i2;
        dst[dst_idx] = src[batch_idx * ne0 + i0];
    } else {
        dst[dst_idx] = T(0);
    }

    (void)ne3;
}

// the host side of ggml_sycl_op_diag: the launch below is the one in diag.cpp (queue, shapes, num_blocks and nd_range)
static void run_diag(sycl::queue & q, float * dst, const float * src,
                     const int64_t ne0, const int64_t ne1, const int64_t ne2, const int64_t ne3) {
    const void * src0_d = src;
    void * dst_d = dst;

    const int64_t n_elems = ne0 * ne1 * ne2 * ne3;
    const int64_t num_blocks = (n_elems + SYCL_DIAG_BLOCK_SIZE - 1) / SYCL_DIAG_BLOCK_SIZE;

    q.parallel_for(
        sycl::nd_range<1>(num_blocks * SYCL_DIAG_BLOCK_SIZE, SYCL_DIAG_BLOCK_SIZE),
        [=](sycl::nd_item<1> item) {
            diag_kernel(static_cast<float *>(dst_d),
                        static_cast<const float *>(src0_d),
                        ne0, ne1, ne2, ne3, n_elems, item);
        }).wait();
}

int main(int argc, char ** argv) {
    // the source shape ne0 x ne1 x ne2 x ne3 (ne1 must be 1); the output is {ne0, ne0, ne2, ne3}
    const int64_t s_ne0 = argc > 1 ? atoll(argv[1]) : 10;
    const int64_t s_ne1 = argc > 2 ? atoll(argv[2]) : 1;
    const int64_t s_ne2 = argc > 3 ? atoll(argv[3]) : 4;
    const int64_t s_ne3 = argc > 4 ? atoll(argv[4]) : 3;
    if (s_ne1 != 1) {
        printf("src ne1 must be 1\n");
        return 2;
    }

    std::optional<sycl::queue> qo;
    try {
        qo.emplace(sycl::gpu_selector_v);
    } catch (const sycl::exception &) {
        printf("no device\n");
        return 70;
    }
    sycl::queue & q = *qo;
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    const int64_t ne0 = s_ne0;
    const int64_t ne1 = s_ne0;   // dst ne1 = ne0: the diag runs along dims 0 and 1
    const int64_t ne2 = s_ne2;
    const int64_t ne3 = s_ne3;
    const int64_t n_elems = ne0 * ne1 * ne2 * ne3;
    const int64_t n_src = ne0 * s_ne1 * ne2 * ne3;

    float * src = sycl::malloc_shared<float>(n_src, q);
    float * dst = sycl::malloc_shared<float>(n_elems + 64, q);
    for (int64_t i = 0; i < n_src; i++) {
        // a known pattern: batch * 1000 + row + 1 (exact in F32; never 0, so a missing write shows up)
        src[i] = (float)((i / ne0) * 1000 + i % ne0 + 1);
    }
    for (int64_t i = 0; i < n_elems + 64; i++) dst[i] = -7.0f;  // output and guard tail start at -7

    run_diag(q, dst, src, ne0, ne1, ne2, ne3);

    int64_t bad = 0, guard = 0;
    for (int64_t i = 0; i < n_elems; i++) {
        const int64_t i0 = i % ne0;
        const int64_t i1 = (i / ne0) % ne1;
        const int64_t i2 = (i / (ne0 * ne1)) % ne2;
        const int64_t i3 = i / (ne0 * ne1 * ne2);
        const int64_t batch = i3 * ne2 + i2;
        const float want = i0 == i1 ? src[batch * ne0 + i0] : 0.0f;
        bad += dst[i] != want;
    }
    for (int64_t i = n_elems; i < n_elems + 64; i++) guard += dst[i] != -7.0f;
    printf("shape %lldx%lldx%lldx%lld: mismatches: %lld of %lld, guard writes: %lld of 64\n",
           (long long)s_ne0, (long long)s_ne1, (long long)s_ne2, (long long)s_ne3,
           (long long)bad, (long long)n_elems, (long long)guard);
    sycl::free(src, q);
    sycl::free(dst, q);
    return bad != 0 || guard != 0;
}
