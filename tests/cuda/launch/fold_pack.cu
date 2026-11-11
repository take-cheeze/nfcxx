// A generic lambda with a trailing return type, called in a fold over the pack of the enclosing template (softmax.cu's
// launch_soft_max_kernels: `(launch_kernel(std::integral_constant<int, Ns>{}) || ...)`), and a launch whose template
// argument is a ternary of a local constant (`block = (ncols > 64 ? 64 : ncols)`). The fold tries each value and runs
// the one that matches; each value writes out[N] = base + N through its own kernel instance.
#include <cuda_runtime.h>
#include <stdio.h>
#include <type_traits>

template <int N> __global__ void kern(int * out, int base) { out[N] = base + N; }

template <int... Ns>
static bool dispatch(int * out, int base, int v) {
    auto launch_kernel = [=](auto I) -> bool {
        constexpr int ncols = decltype(I)::value;
        constexpr int block = (ncols > 64 ? 64 : ncols);
        if (v == ncols) {
            kern<block><<<1, 1>>>(out, base + ncols - block);
            return true;
        }
        return false;
    };
    return (launch_kernel(std::integral_constant<int, Ns>{}) || ...);
}

int main() {
    int * d = 0;
    cudaMalloc((void **) &d, 128 * sizeof(int));
    cudaMemset(d, 0, 128 * sizeof(int));
    bool a = dispatch<2, 5, 7>(d, 100, 2);
    bool b = dispatch<2, 5, 7>(d, 100, 5);
    bool c = dispatch<2, 5, 7>(d, 100, 7);
    bool none = dispatch<2, 5, 7>(d, 100, 9);
    int r[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    cudaMemcpy(r, d, sizeof r, cudaMemcpyDeviceToHost);
    cudaError_t err = cudaDeviceSynchronize();
    printf("fold pack: %s, %d %d %d %d %d\n", cudaGetErrorString(err), a, b, c, none, r[2] + r[5] + r[7]);
    cudaFree(d);
    return !(a && b && c && !none && r[2] == 102 && r[5] == 105 && r[7] == 107);
}
