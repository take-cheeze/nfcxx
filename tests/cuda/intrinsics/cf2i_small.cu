// Float to 1- and 2-byte integers (the IR's cf2i to signed_char and unsigned_short): C's truncation toward zero, as the
// host computes it, for in-range values near both ends of each range. A value outside the target's range traps in the
// IR, so each type gets its own inputs inside its range.
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void k(unsigned short *us, signed char *sc, const float *inu, const float *ins, int nu, int ns) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < nu) us[i] = (unsigned short)inu[i];
  if (i < ns) sc[i] = (signed char)ins[i];
}

int main() {
  const float inu[] = {0.0f, 0.5f, 1.9f, 2.7f, 100.99f, 65534.9f, 65535.0f, 255.9f, 1.0f, 64.7f, 0.99f, 300.5f};
  const float ins[] = {0.0f, 0.5f, -0.5f, -0.99f, -1.9f, -127.9f, -128.0f, 127.99f, 126.5f, -127.5f, 3.0f, 64.7f, -64.7f};
  const int nu = sizeof inu / sizeof inu[0], ns = sizeof ins / sizeof ins[0];
  unsigned short hus[32]; signed char hsc[32];
  float *dinu, *dins; unsigned short *dus; signed char *dsc;
  cudaMalloc(&dinu, sizeof inu); cudaMalloc(&dins, sizeof ins);
  cudaMalloc(&dus, sizeof hus); cudaMalloc(&dsc, sizeof hsc);
  cudaMemcpy(dinu, inu, sizeof inu, cudaMemcpyHostToDevice);
  cudaMemcpy(dins, ins, sizeof ins, cudaMemcpyHostToDevice);
  k<<<1, 32>>>(dus, dsc, dinu, dins, nu, ns);
  cudaError_t err = cudaDeviceSynchronize();
  cudaMemcpy(hus, dus, sizeof hus, cudaMemcpyDeviceToHost);
  cudaMemcpy(hsc, dsc, sizeof hsc, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < nu; i++) if (hus[i] != (unsigned short)inu[i]) bad++;
  for (int i = 0; i < ns; i++) if (hsc[i] != (signed char)ins[i]) bad++;
  printf("cf2i small: %s, %d mismatches\n", cudaGetErrorString(err), bad);
  return bad != 0;
}
