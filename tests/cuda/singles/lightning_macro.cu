// lightning-indexer.cu of llama.cpp: the launch sits in a function-like macro whose parameters give the kernel's
// template arguments. The rewriter sees the macro body, not the expansion, and refuses it: the launch has no kernel
// name in the text it scans. Launches inside macros are not handled yet.
#include <cuda_runtime.h>

template <int N> __global__ void kern(int *p) { p[0] = N; }

#define LAUNCH(N)                 \
    kern<N>                       \
        <<<1, 1>>>(p);

int main() {
    int *p = 0;
    LAUNCH(3)
    return 0;
}
