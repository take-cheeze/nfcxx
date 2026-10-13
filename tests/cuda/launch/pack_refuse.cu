// A launch whose pack is not given by any explicit call: run is only called without template arguments, so its
// instances are not known and the rewrite refuses with the message.
#include <cuda_runtime.h>

template <int... Ns>
__global__ void kpack(int *p) {
  int s = 0;
  ((s += Ns), ...);
  p[threadIdx.x] = s;
}

template <int... Ns>
static void run(int *p) {
  kpack<Ns...><<<1, 32>>>(p);
}

int main() {
  int *d;
  cudaMalloc((void **)&d, 32 * sizeof(int));
  run(d);
  return 0;
}
