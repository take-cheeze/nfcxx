// cudaGetDeviceProperties and cudaDeviceGetAttribute on device 0: the fields that exist in CUDA 13 agree with each other.
#include <cuda_runtime.h>
#include <stdio.h>

int main() {
  cudaDeviceProp p;
  cudaError_t err = cudaGetDeviceProperties(&p, 0);
  int sms = 0, major = 0, minor = 0;
  cudaDeviceGetAttribute(&sms, cudaDevAttrMultiProcessorCount, 0);
  cudaDeviceGetAttribute(&major, cudaDevAttrComputeCapabilityMajor, 0);
  cudaDeviceGetAttribute(&minor, cudaDevAttrComputeCapabilityMinor, 0);
  int ok = err == cudaSuccess && p.multiProcessorCount == sms && p.major == major && p.minor == minor && sms > 0 &&
           p.warpSize == 32 && p.sharedMemPerBlock > 0;
  printf("devprops: %s, sm %d.%d, %d SMs, %s\n", cudaGetErrorString(err), major, minor, sms, ok ? "consistent" : "MISMATCH");
  return ok ? 0 : 1;
}
