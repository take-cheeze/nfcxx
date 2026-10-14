// A launch whose template arguments are constexpr locals of the block holding the launch (ggml-cuda's
// LIGHTNING_INDEXER_CASE and ssm-conv name such locals): the wrapper takes their values.
#include <cstdio>
#include <cuda_runtime.h>

template <int W, int K>
static __global__ void scale(float *p) { p[threadIdx.x] = (float)(W * 10 + K); }

static void run_case(float *d, bool use) {
    if (use) {
        constexpr int K = 3;
        constexpr int W = 4;
        scale<W, K><<<1, 2>>>(d);
    }
}

int main() {
    float *d = nullptr;
    cudaMalloc(&d, 2 * sizeof(float));
    run_case(d, true);
    float h[2] = {0, 0};
    cudaMemcpy(h, d, sizeof(h), cudaMemcpyDeviceToHost);
    cudaFree(d);
    printf("local targs: %s, %g %g\n", (h[0] == 43 && h[1] == 43) ? "no error" : "MISMATCH", h[0], h[1]);
    return 0;
}
