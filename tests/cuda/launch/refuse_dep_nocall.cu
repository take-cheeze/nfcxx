// A dependent launch whose enclosing template is never called with explicit arguments in the unit: no instance.
#include <cuda_runtime.h>
template <typename T> __global__ void k(T *p) { p[0] = (T)1; }
template <typename T> void f(T *p) { k<T><<<1, 1>>>(p); }
int main() { return 0; }
