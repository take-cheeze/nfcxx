// A generic lambda whose parameter is used bare (concat.cu: `concat_non_cont<T, dim>`), with a kernel parameter that is
// only a comment (`int64_t /*extra*/`). Each call of the lambda is one instance; the result is exact.
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdint>
#include <type_traits>

template <typename T, int dim>
__global__ void kern(T *p, int n, int64_t /*extra*/) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p[i] = (T)(dim * 10 + i + 8);
}

template <typename T>
static void run(T *p, int n, int dim, cudaStream_t s) {
    dim3 grid((n + 127) / 128);
    auto launch = [&](auto dim) {
        kern<T, dim><<<grid, 128, 0, s>>>(p, n, 7);
    };
    switch (dim) {
        case 0: launch(std::integral_constant<int, 0>{}); break;
        case 1: launch(std::integral_constant<int, 1>{}); break;
        default: break;
    }
}

int main() {
    const int N = 16;
    int *d;
    cudaMalloc(&d, N * sizeof(int));
    int ok = 1, h[N];
    run<int>(d, N, 0, 0);
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    for (int i = 0; i < N; i++) ok = ok && h[i] == 0 * 10 + i + 7;
    run<int>(d, N, 1, 0);
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    for (int i = 0; i < N; i++) ok = ok && h[i] == 1 * 10 + i + 7;
    printf("bare dim: %s\n", ok ? "exact" : "mismatch");
    cudaFree(d);
    return ok ? 0 : 1;
}
