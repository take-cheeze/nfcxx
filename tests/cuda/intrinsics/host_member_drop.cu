// A host-only member of a device-side class (__host__ int layout(cc), which calls a host helper) is not kept in the
// device unit; the device member layout() is used by the kernel. A rewriter that keeps the host member carries the
// helper, and the device build fails to compile it.
// Result: out = 1 for every thread (the device member is true), exact.
#include <cuda_runtime.h>
#include <stdio.h>

static bool host_dispatch_available(const int cc) { return cc >= 700; }

struct config {
    __host__ int layout(const int cc) const {
        if (host_dispatch_available(cc)) {
            return 1;
        }
        return 0;
    }

    constexpr __device__ bool layout() const { return true; }
};

__global__ void use_config(int *out) {
    config c;
    out[threadIdx.x] = c.layout() ? 1 : 0;
}

int main() {
    const int n = 64;
    int *d, h[n];
    cudaMalloc((void **)&d, sizeof h);
    use_config<<<1, n>>>(d);
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    cudaFree(d);
    int bad = 0;
    for (int i = 0; i < n; ++i) bad += h[i] != 1;
    if (bad != 0) {
        printf("host member drop: %d mismatches\n", bad);
        return 1;
    }
    printf("host member drop: no error, 0 mismatches\n");
    return 0;
}
