// __cvta_generic_to_shared is not lowered: the device compile refuses it by name.
#include <cuda_runtime.h>
__global__ void k(float *p) { p[0] = (float)__cvta_generic_to_shared(p); }
int main() { return 0; }
