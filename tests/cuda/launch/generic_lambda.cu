// A generic lambda whose parameter is a std::integral_constant, launching a kernel with the constant as a template
// argument (ssm-conv.cu's launch_kernel: `constexpr int kNC = decltype(NC)::value`). The lambda is called from a switch
// with three literal values; each call must get its own kernel instance, which writes out[N] = base + N.
#include <cuda_runtime.h>
#include <stdio.h>
#include <type_traits>

template <int N> __global__ void kern(int * out, int base) { out[N] = base + N; }

void dispatch(int * out, int base, int v) {
    auto launch_kernel = [&](auto NC) {
        constexpr int kN = decltype(NC)::value;
        kern<kN><<<1, 1>>>(out, base);
    };
    switch (v) {
        case 2: launch_kernel(std::integral_constant<int, 2>{}); break;
        case 5: launch_kernel(std::integral_constant<int, 5>{}); break;
        case 7: launch_kernel(std::integral_constant<int, 7>{}); break;
        default: break;
    }
}

int main() {
    int * d = 0;
    cudaMalloc((void **) &d, 8 * sizeof(int));
    cudaMemset(d, 0, 8 * sizeof(int));
    dispatch(d, 100, 2);
    dispatch(d, 100, 5);
    dispatch(d, 100, 7);
    int a[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    cudaMemcpy(a, d, sizeof a, cudaMemcpyDeviceToHost);
    cudaError_t err = cudaDeviceSynchronize();
    printf("generic lambda: %s, %d %d %d\n", cudaGetErrorString(err), a[2], a[5], a[7]);
    cudaFree(d);
    return !(a[2] == 102 && a[5] == 105 && a[7] == 107);
}
