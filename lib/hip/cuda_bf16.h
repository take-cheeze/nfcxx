// cuda_bf16.h on the HIP runtime (lib/hip, NFCXX_CUDA_TARGET=amdgpu): HIP's bfloat16 header, with the CUDA names of its
// types (__nv_bfloat16, __nv_bfloat162, nv_bfloat162) that CUDA sources use.
#ifndef NFCXX_HIP_CUDA_BF16_H
#define NFCXX_HIP_CUDA_BF16_H
#include <hip/hip_bf16.h>
typedef __hip_bfloat16 __nv_bfloat16;
typedef __hip_bfloat162 __nv_bfloat162;
typedef __hip_bfloat162 nv_bfloat162;
#endif
