// A parameter and a local named like a dynamic array of another kernel are that declaration in their own scope: the
// dynamic kernel's uses become the dynamic pointer, the parameter's and the local's uses stay the names they are.
// (llama.cpp's fattn.cu: a device helper's `tile_Q` parameter, and a dynamic array of the same name in a kernel.)
// The C-only branch (ggml-common.h's static_assert) is not taken in the device unit: the device unit is C++.
#ifndef __cplusplus
#define static_assert(cond, msg) struct not_cpp_branch
#endif

__device__ float helper(float *const __restrict__ tile, int i) {
  return tile[i];
}

__device__ float local_user(int i) {
  float tile = 2.0f;
  static_assert(sizeof(float) == 4, "f32");
  return tile + i;
}

__global__ void dyn(float *out) {
  extern __shared__ float tile[];
  tile[threadIdx.x] = threadIdx.x;
  out[threadIdx.x] = helper(tile, threadIdx.x) + local_user(threadIdx.x);
}
