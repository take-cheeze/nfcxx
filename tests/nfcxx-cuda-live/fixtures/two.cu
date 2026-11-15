// Two kernels: two entries in the device image (the kernel list and the groups have two names).
__global__ void add1(float *x) { x[threadIdx.x] += 1.0f; }
__global__ void mul3(float *x) { x[threadIdx.x] *= 3.0f; }
