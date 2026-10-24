// A stand-in libcudart.so.12 for tests/cuda/driver/run.sh: cudaGetDriverEntryPointByVersion prints each request
// (base name, version, flags) and hands out functions that check what the trampolines passed them. Nothing of the real
// runtime or driver is needed, so the shim's table and its register and stack handling are checked without a GPU.
#include <stdio.h>
#include <string.h>
typedef unsigned long long u64;
static int f_init(unsigned flags) { return flags == 0 ? 0 : 1; }
static int f_count(int *n) { *n = 2; return 0; }
static int f_ok(void) { return 0; }
// cuLaunchKernel's eleven arguments: six in registers, five on the stack.
static long launched;
static int f_launch(void *f, unsigned gx, unsigned gy, unsigned gz, unsigned bx, unsigned by, unsigned bz, unsigned sh,
                    void *stream, void **params, void **extra) {
  launched = (long)f + gx * 2 + gy * 3 + gz * 5 + bx * 7 + by * 11 + bz * 13 + sh * 17 + (long)stream * 19 +
             (long)params * 23 + (long)extra * 29;
  return 0;
}
long fake_launched(void) { return launched; }
int cudaGetDriverEntryPointByVersion(const char *s, void **fn, unsigned ver, u64 flags, int *status) {
  printf("request %s %u %llu\n", s, ver, flags);
  *status = 0;
  if (!strcmp(s, "cuInit")) *fn = (void *)f_init;
  else if (!strcmp(s, "cuDeviceGetCount")) *fn = (void *)f_count;
  else if (!strcmp(s, "cuLaunchKernel")) *fn = (void *)f_launch;
  else if (!strcmp(s, "cuMemAlloc")) { *fn = 0; *status = 2; }   // "the driver is too old"
  else if (!strcmp(s, "cuModuleLoad")) { *fn = 0; *status = 1; }  // "no such symbol"
  else if (!strcmp(s, "cuGetErrorString") || !strcmp(s, "cuGetErrorName")) { *fn = 0; *status = 1; }
  else *fn = (void *)f_ok;
  return 0;
}
