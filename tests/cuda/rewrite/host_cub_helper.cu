// A host-only helper that calls CUB (cub::DeviceScan, which the device unit cannot carry) and is reached only from host
// code. The device unit must drop it: the kernel the launcher starts writes out[i] = 2 * i, checked exactly.
#include <cuda_runtime.h>
#include <stdio.h>

namespace cub { struct DeviceScan { static void InclusiveSum(void *, size_t &, const int *, int *, int, cudaStream_t) {} }; }

template <typename T> static void scan_host(const T * src, T * dst, int64_t n, cudaStream_t stream) {
    size_t tmp = 0;
    cub::DeviceScan::InclusiveSum(nullptr, tmp, src, dst, (int) n, stream);
}

template <typename T> static __global__ void twice(T * out, int64_t n) {
    int64_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = (T) (2 * i);
}

template <typename T> static void launcher(T * out, int64_t n, cudaStream_t stream) {
    if (n > 1024) scan_host(out, out, n, stream);
    twice<T><<<(n + 63) / 64, 64, 0, stream>>>(out, n);
}

int main() {
    const int64_t n = 200;
    int * d = nullptr;
    cudaMalloc((void **) &d, n * sizeof(int));
    launcher<int>(d, n, 0);
    int h[200] = {};
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    cudaError_t err = cudaDeviceSynchronize();
    int bad = 0;
    for (int64_t i = 0; i < n; i++) bad += h[i] != 2 * i;
    cudaFree(d);
    printf("host cub helper: %s, %d mismatches\n", cudaGetErrorString(err), bad);
    return bad != 0 || err != cudaSuccess;
}
