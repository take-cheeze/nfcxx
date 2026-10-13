// A `using namespace n;` lets device code name n's class templates unqualified (ggml-cuda's mmq-vec-dot.cuh uses
// ggml_cuda_mma's tile that way). The kernel takes the rows of tile<16, 8, float>, from the partial specialization.
#include <cstdio>
#include <cuda_runtime.h>

namespace tiles {
    enum layout { ROW, COL };
    template <int I, int J, typename T, layout L = ROW>
    struct tile {};
    template <int I, int J>
    struct tile<I, J, float, ROW> {
        enum { rows = I, cols = J };   // enum values, not static data members: the device image lowers no globals
    };
}
using namespace tiles;

template <int N>
static __global__ void fill(float *p) {
    typedef tile<16, 8, float> t;
    p[threadIdx.x] = (float) t::rows + (float) (t::cols + N);
}

int main() {
    float *d = nullptr;
    cudaMalloc(&d, 2 * sizeof(float));
    fill<4><<<1, 2>>>(d);
    float h[2] = {0, 0};
    cudaMemcpy(h, d, sizeof(h), cudaMemcpyDeviceToHost);
    cudaFree(d);
    printf("using namespace: %s, %g %g\n", (h[0] == 28 && h[1] == 28) ? "no error" : "MISMATCH", h[0], h[1]);
    return 0;
}
