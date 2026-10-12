// Two templates that instantiate each other through their arguments: the chain is refused.
#include <cuda_runtime.h>
template <typename T> __global__ void k(T *p) { p[0] = (T)1; }
template <typename T> void g(T *p);
template <typename T> void f(T *p) { k<T><<<1, 1>>>(p); g<T>(p); }
template <typename T> void g(T *p) { f<T>(p); }
int main() { float *d = 0; f<float>(d); return 0; }
