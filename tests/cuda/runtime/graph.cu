// A registered kernel launched inside a stream capture, instantiated and replayed with cudaGraphLaunch.
// Expect "graph: no error, 0 mismatches".
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void addone(int *x, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) x[i] += 1;
}

int main() {
  const int n = 512;
  int h[n], o[n];
  for (int i = 0; i < n; i++) h[i] = i;
  int *x = 0;
  cudaMalloc((void **)&x, sizeof h);
  cudaMemcpy(x, h, sizeof h, cudaMemcpyHostToDevice);
  cudaStream_t s;
  cudaStreamCreate(&s);
  cudaError_t err = cudaStreamBeginCapture(s, cudaStreamCaptureModeGlobal);
  addone<<<2, 256, 0, s>>>(x, n);
  addone<<<2, 256, 0, s>>>(x, n);
  cudaGraph_t g = 0;
  if (err == cudaSuccess) err = cudaStreamEndCapture(s, &g);
  cudaGraphExec_t e = 0;
  if (err == cudaSuccess) err = cudaGraphInstantiate(&e, g, 0);
  if (err == cudaSuccess) err = cudaGraphLaunch(e, s);
  if (err == cudaSuccess) err = cudaStreamSynchronize(s);
  cudaMemcpy(o, x, sizeof o, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; i++) bad += o[i] != h[i] + 2;
  printf("graph: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  if (e) cudaGraphExecDestroy(e);
  if (g) cudaGraphDestroy(g);
  cudaStreamDestroy(s);
  cudaFree(x);
  return bad != 0;
}
