// A header with template kernels whose __launch_bounds__ takes macro arguments, as llama.cpp's fattn headers do.
// The driver rewrites __launch_bounds__ only in the main .cu file; the host compile of this header needs the
// empty default from lib/cuda/nfcxx_cuda.h (cuda_runtime.h defines it only under __CUDACC__).
#pragma once
#define KERNEL_STRIDE 256
#define THREADS(D) ((D) / 2)

template <int ncols1>
__launch_bounds__(KERNEL_STRIDE/2, 1)
static __global__ void scale_by(const int * in, int * out, const int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = in[i] * (int) ncols1;
}

template <int D, int ncols1, int ncols2>
__launch_bounds__(THREADS(D), ncols1 * ncols2)
static __global__ void sum_pairs(const int * in, int * out) {
    out[0] = in[0] + D + ncols1 + ncols2;
}
