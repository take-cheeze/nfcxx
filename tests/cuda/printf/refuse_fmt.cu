// A device printf whose format is not a string constant: refused (exit 3), the emitter has no way to name it.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void bad(const char *fmt, int n) {
  if (threadIdx.x < n) printf(fmt, (int)threadIdx.x);
}

int main() {
  bad<<<1, 1>>>("x %d\n", 1);
  return 0;
}
