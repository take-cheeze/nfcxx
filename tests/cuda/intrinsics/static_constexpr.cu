// static constexpr data members with values (int, unsigned, float, double, bool, and a template-parameter-dependent
// value): their uses are folded in device code, and their addresses are read from .const (pathb-ptx-emit.rb,
// scalar_const_init). Compares every result with the host's, exactly.
#include <cstdio>
#include <cuda_runtime.h>

template <int N, typename T>
struct C {
    static constexpr int K = 3;
    static constexpr float F = 2.5f;
    static constexpr unsigned U = 7u;
    static constexpr bool B = true;
    static constexpr int E = N * 2 + K;
    static constexpr double D = 0.1;
    __device__ static T scale(T x) { return x * (T) K + (T) E + (T) F + (T) U + (T) (B ? 1 : 0); }
};

__global__ void kernel(float *out, float x) {
    out[0] = C<4, float>::scale(x);                       // folded uses
    // the pointers are chosen at run time, so the reads go through the constants' addresses (.const)
    const int *pk = &C<4, float>::K;
    const float *pf = &C<4, float>::F;
    const unsigned *pu = &C<4, float>::U;
    const int *pe = &C<4, float>::E;
    const double *pd = &C<4, float>::D;
    if (x > 1000.0f) {
        pk = &C<2, float>::K;
        pf = &C<2, float>::F;
        pu = &C<2, float>::U;
        pe = &C<2, float>::E;
        pd = &C<2, float>::D;
    }
    out[1] = (float) *pk;                                 // an int constant
    out[2] = *pf;                                         // a float constant
    out[3] = (float) *pu;                                 // an unsigned constant
    out[4] = (float) *pe;                                 // template-parameter dependent (N = 4)
    out[5] = (float) *(&C<2, float>::E);                  // template-parameter dependent (N = 2)
    out[6] = (float) *pd;                                 // a double constant
}

static float host_scale(float x) {
    return x * 3.0f + 11.0f + 2.5f + 7.0f + 1.0f;
}

int main() {
    float *d = nullptr;
    cudaMalloc(&d, 7 * sizeof(float));
    int mismatches = 0;
    const float xs[] = {0.0f, 1.0f, 2.0f, -4.0f, 0.5f};
    float want[7] = {0, 3.0f, 2.5f, 7.0f, 11.0f, 7.0f, (float) 0.1};
    for (float x : xs) {
        kernel<<<1, 1>>>(d, x);
        float got[7];
        cudaMemcpy(got, d, sizeof got, cudaMemcpyDeviceToHost);
        want[0] = host_scale(x);
        for (int i = 0; i < 7; i++) {
            if (got[i] != want[i]) {
                mismatches++;
                std::printf("mismatch x=%g i=%d got=%.9g want=%.9g\n", x, i, got[i], want[i]);
            }
        }
    }
    cudaFree(d);
    std::printf("static constexpr: no error, %d mismatches\n", mismatches);
    return mismatches != 0;
}
