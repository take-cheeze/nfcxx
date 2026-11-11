// A kernel launched from a function template whose instances are declared extern, as llama.cpp's mmq.cuh declares
// mul_mat_q_case: each instance is defined by its own unit (inst_2.cu, inst_3.cu), and main.cu only calls them.
#pragma once
#include <cuda_runtime.h>

template <int S, bool Add>
__global__ void scale(int *x, int n) {
    int i = threadIdx.x;
    if (i < n) x[i] = Add ? x[i] + S : x[i] * S;
}

template <int S>
int scale_case(int *x, int n) {
    scale<S, false><<<1, n>>>(x, n);
    scale<S, true><<<1, n>>>(x, n);
    return cudaDeviceSynchronize() == cudaSuccess ? 0 : 1;
}

#define DECL_SCALE_CASE(s) template int scale_case<s>(int *x, int n)
extern DECL_SCALE_CASE(2);
extern DECL_SCALE_CASE(3);
