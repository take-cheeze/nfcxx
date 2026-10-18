// The half2 lanes of the flash-attention vec kernel's V path, one key: tmp = V (4 half2, loaded by one 16-byte copy as
// dequantize_V_f16 does), VKQ += tmp * KQ_k with KQ_k = 1 (the softmax weight of the single key), then VKQ is written back to a
// half buffer with one 16-byte copy (ggml_sycl_memcpy_1<16>) and read lane by lane as float. Every lane 0..7 must equal V.
// Expected output: "half2_vkq_lanes ok".
#include <sycl/sycl.hpp>
#include "../../lib/sycl-ggml/sycl/half_type.hpp"
#include <cstdio>

int main() {
    sycl::queue q;
    sycl::half * V = sycl::malloc_shared<sycl::half>(8, q);
    sycl::half * out = sycl::malloc_shared<sycl::half>(8, q);
    sycl::half * shm = sycl::malloc_shared<sycl::half>(8, q);
    for (int i = 0; i < 8; i++) {
        V[i] = sycl::half(0.25f * (float) (i + 1));
        out[i] = sycl::half(-1.0f);
        shm[i] = sycl::half(0.0f);
    }
    q.parallel_for(sycl::range<1>(1), [=](sycl::id<1>) {
        sycl::half2 tmp[4];
        *(sycl::int4 *) tmp = *(const sycl::int4 *) V;
        sycl::half2 VKQ[4] = { { 0.0f, 0.0f }, { 0.0f, 0.0f }, { 0.0f, 0.0f }, { 0.0f, 0.0f } };
        const sycl::half2 KQ_k(sycl::half(1.0f), sycl::half(1.0f));
        for (int k = 0; k < 4; k++) {
            VKQ[k] += tmp[k] * KQ_k;
        }
        *(sycl::int4 *) shm = *(const sycl::int4 *) VKQ;
        for (int d = 0; d < 8; d++) {
            out[d] = shm[d];
        }
    }).wait();
    int bad = 0;
    for (int d = 0; d < 8; d++) {
        if ((float) out[d] != (float) V[d]) {
            std::printf("lane %d: got %g want %g\n", d, (double) (float) out[d], (double) (float) V[d]);
            bad++;
        }
    }
    std::printf(bad ? "half2_vkq_lanes FAIL %d\n" : "half2_vkq_lanes ok\n", bad);
    return bad != 0;
}
