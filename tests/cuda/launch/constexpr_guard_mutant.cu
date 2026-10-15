// Mutant of constexpr_guard.cu: the condition is negated, so the sparse instances take the else site (tagk<7>) and the
// other instance takes the sparse sites. The check must see mismatches.
#include <cuda_runtime.h>
#include <stdio.h>

template <int K> __global__ void tagk(int *p, int v) { p[threadIdx.x] = v * 10 + K; }

static constexpr __host__ __device__ bool sparse_ok(const int A, const int B) {
    return (A == 512 && B == 1) || (A == 256 && B == 8);
}

typedef void (*kfn)(int *, int);

template <int A, int B> static kfn pick(bool rt) {
    kfn k = nullptr;
    if constexpr (!sparse_ok(A, B)) {
        if (rt) {
            constexpr int K = 1;
            k = tagk<A + K>;
        } else {
            constexpr int K = 2;
            k = tagk<A + K>;
        }
    } else {
        k = tagk<7>;
    }
    return k;
}

static int run(kfn k, int *dp, int v, int expect) {
    void *args[] = {&dp, &v};
    if (cudaLaunchKernel(k, dim3(1), dim3(4), args, 0, 0) != cudaSuccess) return 1000;
    if (cudaDeviceSynchronize() != cudaSuccess) return 1000;
    int h[4];
    cudaMemcpy(h, dp, sizeof h, cudaMemcpyDeviceToHost);
    int bad = 0;
    for (int i = 0; i < 4; i++) bad += h[i] != expect;
    return bad;
}

int main() {
    int *dp;
    cudaMalloc(&dp, 4 * sizeof(int));
    int bad = 0;
    bad += run(pick<512, 1>(true), dp, 3, 3 * 10 + 513);
    bad += run(pick<512, 1>(false), dp, 3, 3 * 10 + 514);
    bad += run(pick<256, 8>(true), dp, 3, 3 * 10 + 257);
    bad += run(pick<256, 8>(false), dp, 3, 3 * 10 + 258);
    bad += run(pick<64, 64>(true), dp, 3, 3 * 10 + 7);
    printf("constexpr guard: %d mismatches\n", bad);
    cudaFree(dp);
    return bad != 0;
}
