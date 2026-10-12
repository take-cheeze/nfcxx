#pragma once
#include "helper.cuh"
__global__ void scale_kernel(int *p, int f) {
  int i = threadIdx.x;
  p[i] = scale_value(i, f);
}
