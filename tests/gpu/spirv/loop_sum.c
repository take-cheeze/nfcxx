/* Runs the SPIR-V of loop.ir (sum of 0..n-1 through a loop with break and a set accumulator) on the first Intel GPU
 * (else the first GPU), as one work item, and checks the sum. Usage: loop_sum FILE.spv. Exit 0 when the sum is right. */
#define CL_TARGET_OPENCL_VERSION 210
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 10

static void check(cl_int err, const char *what) {
  if (err != CL_SUCCESS) {
    fprintf(stderr, "%s: OpenCL error %d\n", what, err);
    exit(2);
  }
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: loop_sum FILE.spv\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  fseek(f, 0, SEEK_END);
  size_t il_len = (size_t)ftell(f);
  rewind(f);
  unsigned char *il = malloc(il_len);
  if (fread(il, 1, il_len, f) != il_len) { fprintf(stderr, "short read\n"); return 2; }
  fclose(f);

  cl_platform_id plat[8];
  cl_uint nplat = 0;
  check(clGetPlatformIDs(8, plat, &nplat), "clGetPlatformIDs");
  cl_device_id dev = NULL, any = NULL;
  for (cl_uint p = 0; p < nplat && !dev; p++) {
    cl_device_id devs[8];
    cl_uint ndev = 0;
    if (clGetDeviceIDs(plat[p], CL_DEVICE_TYPE_GPU, 8, devs, &ndev) != CL_SUCCESS) continue;
    for (cl_uint d = 0; d < ndev && !dev; d++) {
      char vendor[256];
      clGetDeviceInfo(devs[d], CL_DEVICE_VENDOR, sizeof vendor, vendor, NULL);
      if (!any) any = devs[d];
      if (strstr(vendor, "Intel")) dev = devs[d];
    }
  }
  if (!dev) dev = any;
  if (!dev) { fprintf(stderr, "no OpenCL GPU device\n"); return 2; }

  cl_int err;
  cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
  check(err, "clCreateContext");
  cl_command_queue q = clCreateCommandQueueWithProperties(ctx, dev, NULL, &err);
  check(err, "clCreateCommandQueueWithProperties");
  cl_program prog = clCreateProgramWithIL(ctx, il, il_len, &err);
  check(err, "clCreateProgramWithIL");
  err = clBuildProgram(prog, 1, &dev, "", NULL, NULL);
  if (err != CL_SUCCESS) { fprintf(stderr, "build failed (%d)\n", err); return 2; }
  cl_kernel k = clCreateKernel(prog, "_Z3sumPii", &err);
  check(err, "clCreateKernel");

  int host[2] = { 0, N };      /* host[0] receives the sum, the kernel reads n from the argument */
  cl_mem buf = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, sizeof host, host, &err);
  check(err, "clCreateBuffer");
  int n = N;
  check(clSetKernelArg(k, 0, sizeof(cl_mem), &buf), "arg 0");
  check(clSetKernelArg(k, 1, sizeof(int), &n), "arg 1");
  size_t global = 1;
  check(clEnqueueNDRangeKernel(q, k, 1, NULL, &global, NULL, 0, NULL, NULL), "launch");
  check(clEnqueueReadBuffer(q, buf, CL_TRUE, 0, sizeof host, host, 0, NULL, NULL), "read");
  check(clFinish(q), "finish");

  int want = N * (N - 1) / 2;
  printf("sum of 0..%d = %d (expected %d)\n", N - 1, host[0], want);
  return host[0] != want;
}
