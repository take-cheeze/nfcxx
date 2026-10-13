// A static __shared__ array shadows a dynamic one of the same name in its block only: the dynamic kernel's uses become
// the dynamic pointer, the static block's uses stay the array (the device unit must keep `ids[...]` there).
__global__ void dyn(int *out) {
  extern __shared__ int ids[];
  ids[threadIdx.x] = threadIdx.x;
  out[threadIdx.x] = ids[threadIdx.x];
}

__global__ void stat(int *out) {
  __shared__ int ids[4];
  ids[threadIdx.x] = 7;
  out[threadIdx.x] = ids[threadIdx.x];
}
