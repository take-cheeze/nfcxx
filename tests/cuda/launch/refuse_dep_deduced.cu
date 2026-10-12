// The only call of the enclosing template deduces its argument (no explicit template argument): not instantiable.
#include <cuda_runtime.h>
template <typename T> __global__ void k(T *p) { p[0] = (T)1; }
template <typename T> void f(T *p) { k<T><<<1, 1>>>(p); }
int main() { float *d = 0; f(d); return 0; }
