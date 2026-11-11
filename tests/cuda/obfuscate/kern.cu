// Two kernels, one a template, launched with the launch syntax. Used by run.sh: the new names must replace theirs.
__global__ void ob_scale_kernel(float *a, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) a[i] = 2.0f * a[i];
}

template <typename T>
__global__ void ob_offset_kernel(T *a, int n) {
  int i = threadIdx.x;
  if (i < n) a[i] = a[i] + 1;
}

int main() {
  float *d = 0;
  ob_scale_kernel<<<1, 32>>>(d, 32);
  ob_offset_kernel<float><<<1, 32>>>(d, 32);
  return 0;
}
