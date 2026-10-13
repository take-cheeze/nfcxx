// __hgt2_mask (a half2 comparison) is not lowered: the device compile refuses it by name.
#include <cuda_runtime.h>
__global__ void k(unsigned *p) { p[0] = __hgt2_mask(p[1], p[2]); }
int main() { return 0; }
