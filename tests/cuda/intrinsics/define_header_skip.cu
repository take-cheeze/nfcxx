// A macro whose body is an explicit template instantiation, named in its own #define (fattn-tile's
// DECL_FATTN_TILE_CASE), in a unit with a host context type holding host members (std::vector) and a device helper
// in both branches of an #ifdef. The device unit must keep the helper and drop the host type and the macro's
// #define; a rewriter that expands the macro's name in its own header keeps the host type, and the device build fails.
// Result: add_n<3>(pick(40)) + 40 = 84, exact.
#include <cuda_runtime.h>
#include <stdio.h>
#include <vector>

struct ggml_tensor { int ne[4]; };
struct ggml_backend_cuda_context { std::vector<int> join_events; int device; };

#ifdef NFCXX_TEST_BRANCH_A
static __device__ int pick(int x) {
#else
static __device__ int pick(int x) {
#endif
    return x + 1;
}

template <int N> __device__ int add_n(int x) { return x + N; }

__global__ void dev_k(int * out, int a, int b) { out[0] = add_n<3>(pick(a)) + b; }

template <int DKQ, int DV> void run_case(ggml_backend_cuda_context & ctx, int * out) {
    (void) ctx;
    dev_k<<<1, 1>>>(out, DKQ, DV);
}

#define DECL_CASE(DKQ, DV)                             \
    template void run_case                             \
    <DKQ, DV>(ggml_backend_cuda_context & ctx, int * out)

DECL_CASE( 40,  40);

int main() {
    int *d, h = 0;
    cudaMalloc((void **)&d, sizeof h);
    ggml_backend_cuda_context ctx{};
    run_case<40, 40>(ctx, d);
    cudaMemcpy(&h, d, sizeof h, cudaMemcpyDeviceToHost);
    cudaFree(d);
    if (h != 84) {
        printf("define header skip: %d, expected 84\n", h);
        return 1;
    }
    printf("define header skip: no error, 0 mismatches\n");
    return 0;
}
