/* OpenCL counterpart of bench.cpp on the Intel Arc B60 (NEO), with the same three measurements and the same kernel
 * shapes, each the median of 5 timed runs after one untimed warm-up:
 *   (a) one 50000-element vector add, enqueued and read back (blocking), end to end;
 *   (b) N = 10000 enqueues of the small kernel (1 workgroup of 64) on one queue, one clFinish, per dispatch;
 *   (c) the same N dispatches each flushed to the device on its own (clFlush after every enqueue), then one clFinish;
 *       the closest OpenCL analogue of N separate submits.
 * Exit 2 when there is no Intel OpenCL GPU, 1 when the vector add is wrong. */
#define CL_TARGET_OPENCL_VERSION 210
#include <CL/cl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define N_VEC 50000
#define N_SMALL 10000
#define RUNS 5

static const char *kSrc =
    "__kernel void vecadd(__global const float *a, __global const float *b, __global float *c, int n) {\n"
    "  int i = get_global_id(0);\n"
    "  if (i < n) c[i] = a[i] + b[i];\n"
    "}\n"
    "__kernel void small(__global float *sink) {\n"
    "  if (get_local_id(0) == 0) sink[0] = sink[0] + 1.0f;\n"
    "}\n";

static void check(cl_int err, const char *what) {
  if (err != CL_SUCCESS) {
    fprintf(stderr, "%s: OpenCL error %d\n", what, err);
    exit(1);
  }
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int cmp_double(const void *x, const void *y) {
  double a = *(const double *)x, b = *(const double *)y;
  return (a > b) - (a < b);
}

static double median(double *v, int n) {
  qsort(v, n, sizeof v[0], cmp_double);
  return v[n / 2];
}

static void print_series(const char *label, double *v, const char *unit, int per) {
  double med = median(v, RUNS);
  printf("%s: median %.3f %s", label, med, unit);
  if (per > 0) printf(" per dispatch (N=%d)", per);
  printf(" [runs:");
  for (int i = 0; i < RUNS; i++) printf(" %.3f", v[i]);
  printf("]\n");
}

int main(void) {
  cl_platform_id plat[8];
  cl_uint nplat = 0;
  check(clGetPlatformIDs(8, plat, &nplat), "clGetPlatformIDs");
  cl_device_id dev = NULL;
  for (cl_uint p = 0; p < nplat && !dev; p++) {
    cl_device_id devs[8];
    cl_uint ndev = 0;
    if (clGetDeviceIDs(plat[p], CL_DEVICE_TYPE_GPU, 8, devs, &ndev) != CL_SUCCESS) continue;
    for (cl_uint d = 0; d < ndev && !dev; d++) {
      char vendor[256];
      clGetDeviceInfo(devs[d], CL_DEVICE_VENDOR, sizeof vendor, vendor, NULL);
      if (strstr(vendor, "Intel")) dev = devs[d];
    }
  }
  if (!dev) {
    printf("no Intel OpenCL GPU\n");
    return 2;
  }
  char name[256];
  clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
  printf("device: %s (OpenCL)\n", name);

  cl_int err;
  cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
  check(err, "clCreateContext");
  cl_command_queue q = clCreateCommandQueueWithProperties(ctx, dev, NULL, &err);
  check(err, "clCreateCommandQueueWithProperties");
  cl_program prog = clCreateProgramWithSource(ctx, 1, &kSrc, NULL, &err);
  check(err, "clCreateProgramWithSource");
  err = clBuildProgram(prog, 1, &dev, "", NULL, NULL);
  if (err != CL_SUCCESS) {
    size_t logn = 0;
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &logn);
    char *log = malloc(logn + 1);
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, logn, log, NULL);
    fprintf(stderr, "build failed (%d):\n%s\n", err, log);
    return 1;
  }
  cl_kernel kvec = clCreateKernel(prog, "vecadd", &err);
  check(err, "clCreateKernel vecadd");
  cl_kernel ksmall = clCreateKernel(prog, "small", &err);
  check(err, "clCreateKernel small");

  /* (a) data and buffers, uploaded once. */
  float *a = malloc(N_VEC * sizeof(float)), *b = malloc(N_VEC * sizeof(float));
  float *c = malloc(N_VEC * sizeof(float));
  for (int i = 0; i < N_VEC; i++) { a[i] = (float)i; b[i] = 2.0f * (float)i; }
  const size_t vbytes = N_VEC * sizeof(float);
  cl_mem da = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, vbytes, a, &err);
  check(err, "buffer a");
  cl_mem db = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, vbytes, b, &err);
  check(err, "buffer b");
  cl_mem dc = clCreateBuffer(ctx, CL_MEM_READ_WRITE, vbytes, NULL, &err);
  check(err, "buffer c");
  int n = N_VEC;
  check(clSetKernelArg(kvec, 0, sizeof(cl_mem), &da), "arg a");
  check(clSetKernelArg(kvec, 1, sizeof(cl_mem), &db), "arg b");
  check(clSetKernelArg(kvec, 2, sizeof(cl_mem), &dc), "arg c");
  check(clSetKernelArg(kvec, 3, sizeof(int), &n), "arg n");
  size_t vlocal = 128, vglobal = (N_VEC + 127) / 128 * 128;

  double ta[RUNS];
  int vec_bad = 0;
  for (int r = 0; r <= RUNS; r++) {
    double t0 = now_ms();
    check(clEnqueueNDRangeKernel(q, kvec, 1, NULL, &vglobal, &vlocal, 0, NULL, NULL), "enqueue vecadd");
    check(clEnqueueReadBuffer(q, dc, CL_TRUE, 0, vbytes, c, 0, NULL, NULL), "read c");
    double dt = now_ms() - t0;
    if (r > 0) ta[r - 1] = dt;
    for (int i = 0; i < N_VEC; i++) if (c[i] != a[i] + b[i]) { vec_bad++; break; }
  }
  if (vec_bad) {
    printf("vecadd result wrong\n");
    return 1;
  }

  /* Small kernel: one 64-thread workgroup, one word of sink touched. */
  cl_mem sink = clCreateBuffer(ctx, CL_MEM_READ_WRITE, 64, NULL, &err);
  check(err, "buffer sink");
  float zero[16] = {0};
  check(clEnqueueWriteBuffer(q, sink, CL_TRUE, 0, sizeof zero, zero, 0, NULL, NULL), "zero sink");
  check(clSetKernelArg(ksmall, 0, sizeof(cl_mem), &sink), "arg sink");
  size_t slocal = 64, sglobal = 64;
  check(clFinish(q), "finish");

  /* (b) N enqueues, one clFinish. */
  double tb[RUNS];
  for (int r = 0; r <= RUNS; r++) {
    double t0 = now_ms();
    for (int i = 0; i < N_SMALL; i++)
      check(clEnqueueNDRangeKernel(q, ksmall, 1, NULL, &sglobal, &slocal, 0, NULL, NULL), "enqueue small");
    check(clFinish(q), "finish");
    double dt = now_ms() - t0;
    if (r > 0) tb[r - 1] = dt * 1000.0 / N_SMALL;
  }

  /* (c) N enqueues, each flushed on its own, then one clFinish. */
  double tc[RUNS];
  for (int r = 0; r <= RUNS; r++) {
    double t0 = now_ms();
    for (int i = 0; i < N_SMALL; i++) {
      check(clEnqueueNDRangeKernel(q, ksmall, 1, NULL, &sglobal, &slocal, 0, NULL, NULL), "enqueue small");
      check(clFlush(q), "flush");
    }
    check(clFinish(q), "finish");
    double dt = now_ms() - t0;
    if (r > 0) tc[r - 1] = dt * 1000.0 / N_SMALL;
  }

  print_series("(a) vecadd 50000, end to end", ta, "ms", 0);
  print_series("(b) small dispatches, one clFinish", tb, "us", N_SMALL);
  print_series("(c) small dispatches, flushed each", tc, "us", N_SMALL);
  return 0;
}
