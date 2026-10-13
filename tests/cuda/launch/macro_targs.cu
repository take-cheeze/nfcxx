// A macro named only as a template argument of a launch: no kernel body names it, so the device unit must keep the
// definition for the wrapper (ggml-cuda's mmf: MMF_ROWS_PER_BLOCK_CDNA).
#include <cstdio>
#include <cuda_runtime.h>

#define ROWS_CDNA 64

template <int R>
static __global__ void rows(float *p) { p[threadIdx.x] = (float)R; }

int main() {
    float *d = nullptr;
    cudaMalloc(&d, 2 * sizeof(float));
    rows<ROWS_CDNA><<<1, 2>>>(d);
    float h[2] = {0, 0};
    cudaMemcpy(h, d, sizeof(h), cudaMemcpyDeviceToHost);
    cudaFree(d);
    printf("macro targs: %s, %g %g\n", (h[0] == 64 && h[1] == 64) ? "no error" : "MISMATCH", h[0], h[1]);
    return 0;
}
