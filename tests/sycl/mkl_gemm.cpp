// oneapi::mkl::blas::column_major::gemm_batch (lib/sycl-ggml/oneapi/mkl.hpp), the tiled strided form, against a host
// reference that sums the products in k order as the device does. Shapes are not multiples of the tile, all four
// transpose combinations run, with batches, beta 0 and beta 1, float and sycl::half inputs. Expected output: "mkl_gemm ok".
#include "../../lib/sycl-ggml/oneapi/mkl.hpp"
#include <sycl/sycl.hpp>
#include <cmath>
#include <cstdio>
#include <vector>

namespace mkl = oneapi::mkl;

static unsigned rng = 12345u;
static float frand() {
    rng = rng * 1103515245u + 12345u;
    return ((rng >> 8) & 0xffff) / 32768.0f - 1.0f;
}

template <class Ta, class Tb>
static int run_case(sycl::queue &q, bool ta_t, bool tb_t, int m, int n, int k, int batch, float beta) {
    const mkl::transpose ta = ta_t ? mkl::transpose::trans : mkl::transpose::nontrans;
    const mkl::transpose tb = tb_t ? mkl::transpose::trans : mkl::transpose::nontrans;
    // column-major storage: op(A) is m x k, op(B) is k x n, C is m x n
    const int lda = ta_t ? k + 3 : m + 3, ldb = tb_t ? n + 2 : k + 2, ldc = m + 1;
    const int cols_a = ta_t ? m : k, cols_b = tb_t ? k : n;   // columns of the stored A and B
    const int64_t sa = (int64_t)lda * cols_a + 5, sb = (int64_t)ldb * cols_b + 7, sc = (int64_t)ldc * n + 9;
    // host copies; the device buffers are device USM, filled and read back with memcpy
    std::vector<Ta> hA(sa * batch);
    std::vector<Tb> hB(sb * batch);
    std::vector<float> hC(sc * batch);
    for (auto &v : hA) v = (Ta)frand();
    for (auto &v : hB) v = (Tb)frand();
    for (auto &v : hC) v = frand();
    const std::vector<float> c0 = hC;
    Ta *A = sycl::malloc_device<Ta>(sa * batch, q);
    Tb *B = sycl::malloc_device<Tb>(sb * batch, q);
    float *C = sycl::malloc_device<float>(sc * batch, q);
    q.memcpy(A, hA.data(), sizeof(Ta) * hA.size());
    q.memcpy(B, hB.data(), sizeof(Tb) * hB.size());
    q.memcpy(C, hC.data(), sizeof(float) * hC.size()).wait();
    const float alpha = 0.75f;
    mkl::blas::column_major::gemm_batch(q, ta, tb, m, n, k, alpha, A, lda, sa, B, ldb, sb, beta, C, ldc, sc, batch).wait();
    q.memcpy(hC.data(), C, sizeof(float) * hC.size()).wait();
    const auto *Ah = hA.data();
    const auto *Bh = hB.data();
    const float *C_host = hC.data();
    int bad = 0;
    for (int p = 0; p < batch; p++)
        for (int j = 0; j < n; j++)
            for (int i = 0; i < m; i++) {
                float s = 0.0f;
                for (int l = 0; l < k; l++) {
                    const float x = (float)(ta_t ? Ah[p * sa + l + (int64_t)i * lda] : Ah[p * sa + i + (int64_t)l * lda]);
                    const float y = (float)(tb_t ? Bh[p * sb + j + (int64_t)l * ldb] : Bh[p * sb + l + (int64_t)j * ldb]);
                    s += x * y;
                }
                float want = alpha * s;
                if (beta != 0.0f) want += beta * c0[p * sc + i + (int64_t)j * ldc];
                const float got = C_host[p * sc + i + (int64_t)j * ldc];
                if (std::fabs(got - want) > 1e-4f * (1.0f + std::fabs(want))) {
                    if (bad < 4)
                        std::printf("m=%d n=%d k=%d batch=%d ta=%d tb=%d beta=%g: [%d,%d,%d] got %g want %g\n", m, n, k, batch,
                                    (int)ta_t, (int)tb_t, beta, p, i, j, got, want);
                    bad++;
                }
            }
    sycl::free(A, q);
    sycl::free(B, q);
    sycl::free(C, q);
    return bad;
}

int main() {
    sycl::queue q;
    const int shapes[][3] = {{1, 1, 1}, {37, 19, 70}, {64, 64, 16}, {65, 130, 33}, {200, 5, 300}};
    int bad = 0;
    for (const auto &s : shapes)
        for (int batch : {1, 3})
            for (float beta : {0.0f, 1.0f})
                for (int t = 0; t < 4; t++) {
                    bad += run_case<float, float>(q, t & 1, t & 2, s[0], s[1], s[2], batch, beta);
                    bad += run_case<sycl::half, sycl::half>(q, t & 1, t & 2, s[0], s[1], s[2], batch, beta);
                }
    std::printf(bad ? "mkl_gemm FAIL %d\n" : "mkl_gemm ok\n", bad);
    return bad != 0;
}
