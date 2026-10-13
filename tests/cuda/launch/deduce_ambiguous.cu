// A call that gives the template parameter two different types (float and int): refused, with the message.
#include <cuda_runtime.h>

template <typename T> __global__ void kadd(const T *x, const T *y, T *z, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) z[i] = x[i] + y[i];
}

template <typename T> void run2(const T *x, const T *y, T *z, int n) {
  kadd<<<1, 32>>>(x, y, z, n);
}

int main() {
  float *f; int *g; float *z;
  run2(f, g, z, 32);
  return 0;
}
