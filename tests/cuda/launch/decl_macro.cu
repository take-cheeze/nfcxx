// A launch in a template whose instances come from a macro that expands to an explicit instantiation (mmq's
// DECL_MMQ_CASE). The macro's body names its parameter (v), which is not a call: the instance is the expansion's.
#include <cuda_runtime.h>
#include <stdio.h>

template <int V> __global__ void kv(int * o) { o[0] = V * 7; }

template <int V> void run_case(int * o) {
    kv<V><<<1, 1>>>(o);
}

#define DECL_CASE(v) template void run_case<v>(int *);
DECL_CASE(2)

int main() {
    int * d = 0;
    cudaMalloc((void **) &d, sizeof(int));
    run_case<2>(d);
    int r = 0;
    cudaMemcpy(&r, d, sizeof r, cudaMemcpyDeviceToHost);
    cudaError_t err = cudaDeviceSynchronize();
    printf("decl macro: %s, %d\n", cudaGetErrorString(err), r);
    cudaFree(d);
    return !(r == 14);
}
