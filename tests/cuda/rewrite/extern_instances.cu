// Explicit instantiation declarations (extern template, directly and through a macro, as llama.cpp's mmq.cuh and
// fattn-mma-f16.cuh declare them) are instances another unit defines: their kernels are not this unit's, even where
// the unit calls them. The explicit instantiation definition (DECL_CASE(2), as an mmq-instance-*.cu file has) is.
// Only k<2, false> and k<2, true> get wrappers.
#include <cuda_runtime.h>

template <int T, bool F>
__global__ void k(float *x) { x[threadIdx.x] += T + F; }

template <int T>
void run_case(float *x) {
    k<T, false><<<1, 32>>>(x);
    k<T, true><<<1, 32>>>(x);
}

#define DECL_CASE(t) template void run_case<t>(float *x)
#define DECL_CASES_2(t) extern DECL_CASE((t)/1); extern DECL_CASE((t)/2)
extern DECL_CASE(1);
extern DECL_CASE(2);
extern template void run_case<3>(float *x);
DECL_CASES_2(8)

void dispatch(int t, float *x) {
    if (t == 3) run_case<3>(x);
    else if (t == 4) run_case<8/2>(x);
    else run_case<5>(x);
}

DECL_CASE(2);
