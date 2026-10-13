// A launch whose flag argument is a local constexpr of its enclosing template's branch (mmq's mul_mat_q_case:
// `constexpr bool fallback = true;` in one branch, `false` in the other, passed on as a template argument).
// Each branch's instance must get its own value: the kernel writes 40 + flag.
#include <cuda_runtime.h>
#include <stdio.h>

template <int J, bool fallback> __global__ void kern(int * out) { out[J] = 40 + (fallback ? 1 : 0); }

template <int J, bool fallback> void launch(int * out) {
    kern<J, fallback><<<1, 1>>>(out);
}

template <bool fallback> void switch_J(int * out) {
    launch<3, fallback>(out);
}

template <int N> void dispatch(int * out, bool need) {
    if (need) {
        constexpr bool fallback = true;
        switch_J<fallback>(out);
    } else {
        constexpr bool fallback = false;
        switch_J<fallback>(out);
    }
}

int main() {
    int * d = 0;
    cudaMalloc((void **) &d, 4 * sizeof(int));
    cudaMemset(d, 0, 4 * sizeof(int));
    dispatch<0>(d, true);
    int a[4] = {0, 0, 0, 0};
    cudaMemcpy(a, d, sizeof a, cudaMemcpyDeviceToHost);
    int first = a[3];
    dispatch<0>(d, false);
    cudaMemcpy(a, d, sizeof a, cudaMemcpyDeviceToHost);
    cudaError_t err = cudaDeviceSynchronize();
    printf("local const: %s, %d %d\n", cudaGetErrorString(err), first, a[3]);
    cudaFree(d);
    return !(first == 41 && a[3] == 40);
}
