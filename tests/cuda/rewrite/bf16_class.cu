// nv_bfloat16 as a class in a device unit: its converting constructor, operator float and an arithmetic operator
// (the device prelude's class and operators), with no other host-only code in the unit.
#include <cuda_bf16.h>

__global__ void scale(const float *in, float *out) {
  __nv_bfloat16 x = __float2bfloat16(in[threadIdx.x]);
  __nv_bfloat16 y = x * x;
  out[threadIdx.x] = __bfloat162float(y);
}
