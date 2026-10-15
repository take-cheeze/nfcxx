// A plain file-scope variable read by device code: nvcc rejects it ("identifier is undefined in device code"), so the
// rewriter refuses it by name.
#include <cuda_runtime.h>
static int table[4] = {1, 2, 3, 4};
__device__ float pick(int i) { return table[i] * 2.0f; }
__global__ void k(float *out) {
  int i = threadIdx.x;
  if (i < 4) out[i] = pick(i);
}
int main() { return 0; }
