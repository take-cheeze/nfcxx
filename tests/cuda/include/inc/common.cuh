// Shared declarations for the include test: reached from sub/helper.cuh as "../inc/common.cuh".
__device__ __host__ inline int scale_factor() { return 3; }
__device__ __host__ inline int scaled(int x) { return x * scale_factor(); }
