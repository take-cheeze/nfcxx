// A parameter pack followed by a typename: `template <int... Ns, typename T>`. The pack is greedy, so the explicit
// arguments all go to Ns and T is deduced from the call's arguments (softmax.cu's launch_soft_max_kernels<..., 4096>(x,
// mask, ...) leaves T to mask). The fold runs the one value that matches; kern writes out[N] = in[0] + N with T = int.
#include <cuda_runtime.h>
#include <stdio.h>

template <bool s, int N, typename T> __global__ void kern(const T * in, T * out) { out[N] = in[0] + (T) N + (T) 1; }

template <int... Ns, typename T>
static bool dispatch(const T * in, T * out, int v) {
    auto launch_kernel = [=](auto I) -> bool {
        constexpr int n = decltype(I)::value;
        if (v == n) {
            kern<true, n, T><<<1, 1>>>(in, out);
            return true;
        }
        return false;
    };
    return (launch_kernel(std::integral_constant<int, Ns>{}) || ...);
}

int main() {
    int * din = 0, * dout = 0;
    cudaMalloc((void **) &din, sizeof(int));
    cudaMalloc((void **) &dout, 8 * sizeof(int));
    int one = 100;
    cudaMemcpy(din, &one, sizeof(int), cudaMemcpyHostToDevice);
    cudaMemset(dout, 0, 8 * sizeof(int));
    bool a = dispatch<2, 5, 7>(din, dout, 5);
    cudaError_t err = cudaDeviceSynchronize();
    int r[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    cudaMemcpy(r, dout, sizeof r, cudaMemcpyDeviceToHost);
    int bad = 0;
    if (!a || r[5] != 105 || r[2] != 0 || r[7] != 0) bad = 1;
    printf("pack trailing: %s, %d mismatches\n", cudaGetErrorString(err), bad);
    cudaFree(din);
    cudaFree(dout);
    return bad;
}
