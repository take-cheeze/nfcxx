// __shared__ __align__(N): the device image does not carry the alignment of a shared object (conv2d's int4 stores).
#include <cuda_runtime.h>

static __global__ void k(int *p) {
    __shared__ __align__(16) int s[64];
    s[threadIdx.x] = p[threadIdx.x];
    p[threadIdx.x] = s[threadIdx.x];
}
