// Included from a.cu as "sub/helper.cuh"; it includes "../inc/common.cuh" relative to its own directory.
#include "../inc/common.cuh"
__device__ inline int helper_value(int x) { return scaled(x) + 1; }
