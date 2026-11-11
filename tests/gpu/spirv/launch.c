/* Loads a SPIR-V kernel (argv[1]) with OpenCL on the first GPU device and runs it as vecAdd (argv[2]): the kernel
 * takes (float *A, float *B, float *C, int vectorLength), and the launch covers the rounded-up range in groups of 128.
 * Checks every element of C against A + B and that the 64 floats past C are untouched. Exit 0 when all match. */
#define CL_TARGET_OPENCL_VERSION 210
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 50000
#define GUARD 64
#define LOCAL 128

static void check(cl_int err, const char *what) {
  if (err != CL_SUCCESS) {
    fprintf(stderr, "%s: OpenCL error %d\n", what, err);
    exit(2);
  }
}

static unsigned char *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(2); }
  fseek(f, 0, SEEK_END);
  *len = (size_t)ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *buf = malloc(*len);
  if (fread(buf, 1, *len, f) != *len) { fprintf(stderr, "short read\n"); exit(2); }
  fclose(f);
  return buf;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: launch FILE.spv KERNEL\n"); return 2; }
  size_t il_len;
  unsigned char *il = read_file(argv[1], &il_len);

  cl_platform_id plat[8];
  cl_uint nplat = 0;
  check(clGetPlatformIDs(8, plat, &nplat), "clGetPlatformIDs");
  /* The first Intel GPU (the XPU this backend targets), else the first GPU of any vendor. */
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
  char name[256];
  clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
  printf("device: %s\n", name);

  cl_int err;
  cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
  check(err, "clCreateContext");
  cl_command_queue q = clCreateCommandQueueWithProperties(ctx, dev, NULL, &err);
  check(err, "clCreateCommandQueueWithProperties");
  cl_program prog = clCreateProgramWithIL(ctx, il, il_len, &err);
  check(err, "clCreateProgramWithIL");
  err = clBuildProgram(prog, 1, &dev, "", NULL, NULL);
  if (err != CL_SUCCESS) {
    size_t logn = 0;
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &logn);
    char *log = malloc(logn + 1);
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, logn, log, NULL);
    fprintf(stderr, "build failed (%d):\n%s\n", err, log);
    return 2;
  }
  cl_kernel k = clCreateKernel(prog, argv[2], &err);
  check(err, "clCreateKernel");

  float *a = malloc(N * sizeof(float)), *b = malloc(N * sizeof(float));
  float *c = malloc((N + GUARD) * sizeof(float));
  for (int i = 0; i < N; i++) { a[i] = (float)i; b[i] = 2.0f * (float)i; }
  for (int i = 0; i < N + GUARD; i++) c[i] = -1.0f;

  cl_mem da = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * sizeof(float), a, &err);
  check(err, "buffer a");
  cl_mem db = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N * sizeof(float), b, &err);
  check(err, "buffer b");
  cl_mem dc = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, (N + GUARD) * sizeof(float), c, &err);
  check(err, "buffer c");
  int n = N;
  check(clSetKernelArg(k, 0, sizeof(cl_mem), &da), "arg 0");
  check(clSetKernelArg(k, 1, sizeof(cl_mem), &db), "arg 1");
  check(clSetKernelArg(k, 2, sizeof(cl_mem), &dc), "arg 2");
  check(clSetKernelArg(k, 3, sizeof(int), &n), "arg 3");

  size_t local = LOCAL;
  size_t global = (N + LOCAL - 1) / LOCAL * LOCAL;
  check(clEnqueueNDRangeKernel(q, k, 1, NULL, &global, &local, 0, NULL, NULL), "launch");
  check(clEnqueueReadBuffer(q, dc, CL_TRUE, 0, (N + GUARD) * sizeof(float), c, 0, NULL, NULL), "read");
  check(clFinish(q), "finish");

  long bad = 0, guard = 0;
  for (int i = 0; i < N; i++)
    if (c[i] != a[i] + b[i]) bad++;
  for (int i = N; i < N + GUARD; i++)
    if (c[i] != -1.0f) guard++;
  printf("mismatches: %ld of %d, guard writes: %ld of %d\n", bad, N, guard, GUARD);
  return bad != 0 || guard != 0;
}
