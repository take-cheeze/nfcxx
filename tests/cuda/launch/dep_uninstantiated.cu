// A dependent launch in a template that the unit never calls: nothing instantiates it, so nothing is emitted for it
// (nvcc compiles nothing for it either). The launch stays a dependent call, and the program runs unchanged.
#include <cuda_runtime.h>
#include <cstdio>
template <typename T> __global__ void k(T *p) { p[0] = (T)1; }
template <typename T> void f(T *p) { k<T><<<1, 1>>>(p); }
int main() {
  std::printf("dep uninstantiated: no error\n");
  return 0;
}
