// The ggml-cuda launch helper (common.cuh, ggml_cuda_kernel_launch) with template kernels: a kernel instance is named
// by its template arguments, and a trailing parameter with a default (a file-level constant) takes the default.
// Without PDL the helper is the launch followed by CUDA_CHECK(cudaGetLastError()); the rewrite gives that form.
#include <cuda_runtime.h>
#include <stdio.h>

#define CUDA_CHECK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { printf("cuda error: %s\n", cudaGetErrorString(e_)); } } while (0)

struct ggml_cuda_kernel_launch_params {
    dim3 block_nums;
    dim3 block_dims;
    size_t shmem;
    cudaStream_t stream;
    ggml_cuda_kernel_launch_params(const dim3 & g, const dim3 & b, const size_t s, const cudaStream_t st)
        : block_nums(g), block_dims(b), shmem(s), stream(st) {}
};

template <typename Kernel, typename... Args>
static __inline__ void ggml_cuda_kernel_launch(Kernel kernel, const ggml_cuda_kernel_launch_params & launch_params, Args&&... args) {
    kernel<<<launch_params.block_nums, launch_params.block_dims, launch_params.shmem, launch_params.stream>>>(std::forward<Args>(args)... );
    CUDA_CHECK(cudaGetLastError());
}

constexpr int helper_default_m = 4;

// out[i] = in[i] * s + N * 10 + M
template <int N, typename T, int M = helper_default_m>
__global__ void helper_affine(const T * in, T * out, int n, T s) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        out[i] = in[i] * s + (T)(N * 10 + M);
    }
}

int main() {
    const int n = 300;
    float * h_in = (float *) malloc(n * sizeof(float));
    for (int i = 0; i < n; i++) h_in[i] = (float) i;
    float * d_in = nullptr, * d_out = nullptr;
    cudaMalloc(&d_in, n * sizeof(float));
    cudaMalloc(&d_out, n * sizeof(float));
    cudaMemcpy(d_in, h_in, n * sizeof(float), cudaMemcpyHostToDevice);

    const dim3 block(128, 1, 1);
    const dim3 grid((n + 127) / 128, 1, 1);
    const ggml_cuda_kernel_launch_params lp(grid, block, 0, 0);

    // explicit N and T; M takes its default (helper_default_m = 4)
    ggml_cuda_kernel_launch(helper_affine<2, float>, lp, d_in, d_out, n, 3.0f);
    float * h_out = (float *) malloc(n * sizeof(float));
    cudaMemcpy(h_out, d_out, n * sizeof(float), cudaMemcpyDeviceToHost);

    int bad = 0;
    for (int i = 0; i < n; i++) {
        float want = h_in[i] * 3.0f + (float)(2 * 10 + 4);
        if (h_out[i] != want) bad++;
    }
    printf("helper launch: %s, %d mismatches\n", cudaGetErrorString(cudaGetLastError()), bad);
    cudaFree(d_in);
    cudaFree(d_out);
    free(h_in);
    free(h_out);
    return bad != 0;
}
