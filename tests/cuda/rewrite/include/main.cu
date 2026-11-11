#include "h0.cuh"
__global__ void k(int *o) { o[0] = f0(1) + f8(2); }
// Calls every header's function, so the device unit keeps f1 through f7 (each reached through its include chain).
__global__ void k2(int *o) { o[1] = f1(1) + f2(1) + f3(1) + f4(1) + f5(1) + f6(1) + f7(1); }
