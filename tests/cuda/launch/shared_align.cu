// __shared__ __align__(16) in a launched kernel: the alignment is carried to the device image's .shared declaration
// (it was refused by name before). A 16-byte aligned int array, filled by a launch and read back on the host.
#include <cuda_runtime.h>
#include <stdio.h>

static __global__ void k(int *p) {
    __shared__ __align__(16) int s[64];
    s[threadIdx.x] = 2 * threadIdx.x;
    __syncthreads();
    p[threadIdx.x] = s[63 - threadIdx.x];
}

int main() {
    int *d, h[64], bad = 0;
    cudaMalloc((void **)&d, sizeof h);
    k<<<1, 64>>>(d);
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    for (int i = 0; i < 64; i++) bad += h[i] != 2 * (63 - i);
    printf("shared align launch: no error, %d mismatches\n", bad);
    return bad != 0;
}
