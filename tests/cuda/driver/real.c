// The driver API through the real libcudart: without a driver every call fails cleanly (CUDA_ERROR_NO_DEVICE) instead
// of the program failing to load; with one, cuInit succeeds and there is a device.
#include <cuda.h>
#include <stdio.h>
int main(void) {
  const char *n = 0;
  CUresult r = cuInit(0);
  cuGetErrorName(r, &n);
  int count = 0;
  if (r == CUDA_SUCCESS) cuDeviceGetCount(&count);
  printf("cuInit %s devices %s\n", n, count > 0 ? "some" : "none");
  return 0;
}
