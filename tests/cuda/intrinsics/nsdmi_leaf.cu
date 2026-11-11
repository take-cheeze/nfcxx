// A local multidimensional array of a class with a default member initializer (`int v = 3`) is default-initialized
// leaf by leaf: the front end gives one constant repeated over all six innermost elements of Cell C[2][3]. The IR
// printer used to refuse that repeat ("unsupported init repeat"); it now stores the constant into each leaf in order.
// Each cell starts at 3, so the sum is 6*3 = 18, plus the i added to one cell. Checked exactly on the device.
#include <cuda_runtime.h>
#include <stdio.h>

struct Cell {
  int v = 3;
};

template <int A, int B>
__device__ int sum_cells(int i) {
  Cell C[A][B];
  C[i % A][i % B].v += i;
  int s = 0;
  for (int a = 0; a < A; a++)
    for (int b = 0; b < B; b++) s += C[a][b].v;
  return s;
}

__global__ void k(int *out, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) out[i] = sum_cells<2, 3>(i);
}

int main() {
  const int n = 64;
  int host[64];
  int *dout;
  cudaMalloc((void **)&dout, n * sizeof(int));
  k<<<1, n>>>(dout, n);
  cudaError_t err = cudaDeviceSynchronize();
  if (err != cudaSuccess) {
    printf("nsdmi leaf: kernel error %s\n", cudaGetErrorString(err));
    return 1;
  }
  cudaMemcpy(host, dout, n * sizeof(int), cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++)
    if (host[i] != 18 + i) bad++;
  printf("nsdmi leaf: no error, %d mismatches\n", bad);
  cudaFree(dout);
  return bad != 0;
}
