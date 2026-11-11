// A 16-byte copy of an array of sycl::half2 into an array of sycl::half in a device kernel, as ggml-sycl's flash-attention
// vec kernel does (ggml_sycl_memcpy_1<16>: one sycl::int4 assignment). Each half lane must arrive. Expected output:
// "half2_int4_copy ok".
#include <sycl/sycl.hpp>
#include "../../lib/sycl-ggml/sycl/half_type.hpp"
#include <cstdio>

int main() {
    const int N = 8;  // work-items, each copying its own 4 half2 (16 bytes)
    sycl::queue q;
    sycl::half2 * src = sycl::malloc_shared<sycl::half2>(4 * N, q);
    sycl::half * dst = sycl::malloc_shared<sycl::half>(8 * N, q);
    for (int i = 0; i < 4 * N; i++) src[i] = sycl::half2(sycl::half(1.0f + 2 * i), sycl::half(2.0f + 2 * i));
    for (int i = 0; i < 8 * N; i++) dst[i] = sycl::half(-1.0f);
    q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> it) {
        const int w = (int) it[0];
        sycl::half2 tmp[4];
        for (int k = 0; k < 4; k++) tmp[k] = src[4 * w + k];
        *(sycl::int4 *) (dst + 8 * w) = *(const sycl::int4 *) tmp;
    }).wait();
    int bad = 0;
    for (int i = 0; i < 8 * N; i++)
        if ((float) dst[i] != (float) (1 + i)) bad++;
    std::printf(bad ? "half2_int4_copy FAIL %d\n" : "half2_int4_copy ok\n", bad);
    return bad != 0;
}
