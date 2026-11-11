// A device function's address used as a value (a function pointer in a local): stored, then compared on the GPU.
// The kernel reports exact flags: the stored pointer equals twice and not plus3. The host checks the flags.
#include <cstdio>
#include <cuda_runtime.h>
__device__ int twice(int x) { return 2 * x; }
__device__ int plus3(int x) { return x + 3; }
typedef int (*op_t)(int);
__global__ void flags(int *out) {
    op_t f = twice;
    out[0] = (f == twice) ? 1 : 0;
    out[1] = (f == plus3) ? 1 : 0;
}
int main() {
    int *d, h[2];
    cudaMalloc(&d, 2 * sizeof(int));
    flags<<<1, 1>>>(d);
    cudaMemcpy(h, d, 2 * sizeof(int), cudaMemcpyDeviceToHost);
    int bad = (h[0] != 1) + (h[1] != 0);
    printf("fnptr addr: %d mismatches\n", bad);
    return bad != 0;
}
