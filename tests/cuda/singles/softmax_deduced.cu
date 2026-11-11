// softmax.cu of llama.cpp: a template kernel whose last template parameter is deduced from the arguments
// (soft_max_f32<true, ncols, block><<<...>>>(x, ...), with T deduced). The rewriter refuses it: the explicit
// arguments must give every template parameter. Deduced template arguments are not handled yet.
#include <cuda_runtime.h>

template <bool B, int N, typename T>
__global__ void kern(T *p) { p[0] = (T)(B ? N : 0); }

int main() {
    float *p = 0;
    kern<true, 3><<<1, 1>>>(p);
    return 0;
}
