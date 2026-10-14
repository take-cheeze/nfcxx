// An enum in an extern "C" block (as ggml_sort_order is in ggml.h) used as a template argument of a device function
// and of a kernel template; and a static __global__ kernel, launched from the host (external linkage in the device unit).
// Prints "enum extern block: no error, N mismatches".
#include <cstdio>
#include <cuda_runtime.h>

extern "C" {
enum sort_order { SORT_ASC, SORT_DESC };
}

template <sort_order order>
__device__ __forceinline__ int pick(int a, int b) { return order == SORT_ASC ? a : b; }

template <sort_order order>
__global__ void sel(int *out, int a, int b) { out[threadIdx.x] = pick<order>(a, b) + threadIdx.x; }

static __global__ void twice(int *out, int v) { out[threadIdx.x] = v * 2; }

int main() {
    const int n = 4;
    int *d; cudaMalloc(&d, n * sizeof(int));
    int h[n], bad = 0;
    sel<SORT_ASC><<<1, n>>>(d, 3, 9);
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    for (int i = 0; i < n; i++) bad += h[i] != 3 + i;
    sel<SORT_DESC><<<1, n>>>(d, 3, 9);
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    for (int i = 0; i < n; i++) bad += h[i] != 9 + i;
    twice<<<1, n>>>(d, 7);
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    for (int i = 0; i < n; i++) bad += h[i] != 14;
    printf("enum extern block: no error, %d mismatches\n", bad);
    return bad != 0;
}
