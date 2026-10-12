#include "h0.cuh"
__global__ void k(int *o) { o[0] = f0(1) + f8(2); }
