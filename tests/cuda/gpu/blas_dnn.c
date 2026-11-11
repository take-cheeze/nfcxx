/* cuBLAS SGEMM and a cuDNN convolution on the GPU, checked against CPU references, plus driver API calls, for
   tests/cuda/gpu/run.sh. Linked with -lcuda: through nfcc and nfcxx the driver calls go through libcudart
   (docs/notes/cuda-driver.md). Without a driver it prints the CUresult of cuInit and stops. */
#include <cuda.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cudnn.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#define CK(x) do { int e_ = (int)(x); if (e_) { printf("FAIL %s = %d (line %d)\n", #x, e_, __LINE__); return 1; } } while (0)
static float frand(unsigned *s) { *s = *s * 1103515245u + 12345u; return (float)((*s >> 8) & 0xffff) / 65536.0f - 0.5f; }
int main(void) {
  unsigned seed = 1;
  int ver = 0, n = 0, maj = 0, min = 0;
  CUdevice dev; char name[128];
  CUresult r = cuInit(0);
  if (r != CUDA_SUCCESS) {
    const char *en = "?";
    cuGetErrorName(r, &en);
    printf("cuInit %s\n", en);
    return 0;
  }
  CK(cuDriverGetVersion(&ver)); CK(cuDeviceGetCount(&n)); CK(cuDeviceGet(&dev, 0));
  CK(cuDeviceGetName(name, sizeof name, dev));
  CK(cuDeviceGetAttribute(&maj, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, dev));
  CK(cuDeviceGetAttribute(&min, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, dev));
  printf("driver %d devices %d %s sm_%d%d\n", ver, n, name, maj, min);

  /* cuBLAS: C = A*B, column-major M x K times K x N */
  enum { M = 257, K = 129, N = 65 };
  float *A = (float *)malloc(sizeof(float) * M * K), *B = (float *)malloc(sizeof(float) * K * N);
  float *C = (float *)malloc(sizeof(float) * M * N), *R = (float *)malloc(sizeof(float) * M * N);
  for (int i = 0; i < M * K; i++) A[i] = frand(&seed);
  for (int i = 0; i < K * N; i++) B[i] = frand(&seed);
  for (int j = 0; j < N; j++) for (int i = 0; i < M; i++) {
    double s = 0; for (int k = 0; k < K; k++) s += (double)A[i + k * M] * B[k + j * K]; R[i + j * M] = (float)s;
  }
  float *dA, *dB, *dC;
  CK(cudaMalloc((void **)&dA, sizeof(float) * M * K)); CK(cudaMalloc((void **)&dB, sizeof(float) * K * N));
  CK(cudaMalloc((void **)&dC, sizeof(float) * M * N));
  CK(cudaMemcpy(dA, A, sizeof(float) * M * K, cudaMemcpyHostToDevice));
  CK(cudaMemcpy(dB, B, sizeof(float) * K * N, cudaMemcpyHostToDevice));
  cublasHandle_t h; CK(cublasCreate(&h));
  int cbv = 0; CK(cublasGetVersion(h, &cbv));
  CK(cublasSetMathMode(h, CUBLAS_PEDANTIC_MATH));
  float one = 1.0f, zero = 0.0f;
  CK(cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, M, N, K, &one, dA, M, dB, K, &zero, dC, M));
  CK(cudaMemcpy(C, dC, sizeof(float) * M * N, cudaMemcpyDeviceToHost));
  double err = 0; for (int i = 0; i < M * N; i++) err = fmax(err, fabs(C[i] - R[i]));
  printf("cublas %d sgemm %dx%dx%d max err %.2e %s\n", cbv, M, N, K, err, err < 1e-4 ? "ok" : "BAD");
  CK(cublasDestroy(h));

  /* cuDNN: NCHW conv, 1x3x16x16 input, 4x3x3x3 filter, pad 1 */
  enum { CI = 3, H = 16, W = 16, CO = 4, KH = 3, KW = 3 };
  float x[CI * H * W], w[CO * CI * KH * KW], y[CO * H * W], yr[CO * H * W];
  for (int i = 0; i < CI * H * W; i++) x[i] = frand(&seed);
  for (int i = 0; i < CO * CI * KH * KW; i++) w[i] = frand(&seed);
  for (int o = 0; o < CO; o++) for (int r = 0; r < H; r++) for (int c = 0; c < W; c++) {
    double s = 0;
    for (int ci = 0; ci < CI; ci++) for (int a = 0; a < KH; a++) for (int b = 0; b < KW; b++) {
      int rr = r + a - 1, cc = c + b - 1;
      if (rr >= 0 && rr < H && cc >= 0 && cc < W) s += (double)x[(ci * H + rr) * W + cc] * w[((o * CI + ci) * KH + a) * KW + b];
    }
    yr[(o * H + r) * W + c] = (float)s;
  }
  cudnnHandle_t dn; CK(cudnnCreate(&dn));
  cudnnTensorDescriptor_t xd, yd; cudnnFilterDescriptor_t wd; cudnnConvolutionDescriptor_t cd;
  CK(cudnnCreateTensorDescriptor(&xd)); CK(cudnnCreateTensorDescriptor(&yd));
  CK(cudnnCreateFilterDescriptor(&wd)); CK(cudnnCreateConvolutionDescriptor(&cd));
  CK(cudnnSetTensor4dDescriptor(xd, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, 1, CI, H, W));
  CK(cudnnSetFilter4dDescriptor(wd, CUDNN_DATA_FLOAT, CUDNN_TENSOR_NCHW, CO, CI, KH, KW));
  CK(cudnnSetConvolution2dDescriptor(cd, 1, 1, 1, 1, 1, 1, CUDNN_CROSS_CORRELATION, CUDNN_DATA_FLOAT));
  int on, oc, oh, ow; CK(cudnnGetConvolution2dForwardOutputDim(cd, xd, wd, &on, &oc, &oh, &ow));
  CK(cudnnSetTensor4dDescriptor(yd, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, on, oc, oh, ow));
  cudnnConvolutionFwdAlgoPerf_t perf[8]; int got = 0;
  CK(cudnnGetConvolutionForwardAlgorithm_v7(dn, xd, wd, cd, yd, 8, &got, perf));
  size_t ws = 0; CK(cudnnGetConvolutionForwardWorkspaceSize(dn, xd, wd, cd, yd, perf[0].algo, &ws));
  float *dx, *dw, *dy; void *dws = 0;
  CK(cudaMalloc((void **)&dx, sizeof x)); CK(cudaMalloc((void **)&dw, sizeof w)); CK(cudaMalloc((void **)&dy, sizeof y));
  if (ws) CK(cudaMalloc(&dws, ws));
  CK(cudaMemcpy(dx, x, sizeof x, cudaMemcpyHostToDevice)); CK(cudaMemcpy(dw, w, sizeof w, cudaMemcpyHostToDevice));
  CK(cudnnConvolutionForward(dn, &one, xd, dx, wd, dw, cd, perf[0].algo, dws, ws, &zero, yd, dy));
  CK(cudaMemcpy(y, dy, sizeof y, cudaMemcpyDeviceToHost));
  err = 0; for (int i = 0; i < CO * H * W; i++) err = fmax(err, fabs(y[i] - yr[i]));
  printf("cudnn %zu conv %dx%d algo %d out %dx%dx%dx%d max err %.2e %s\n", cudnnGetVersion(), KH, KW, (int)perf[0].algo,
         on, oc, oh, ow, err, err < 1e-3 ? "ok" : "BAD");
  CK(cudnnDestroy(dn));

  CUcontext ctx; size_t fr, tot;
  CK(cuCtxGetCurrent(&ctx)); CK(cuMemGetInfo(&fr, &tot));
  printf("ctx %s mem total %zu MiB\n", ctx ? "primary" : "none", tot >> 20);
  return 0;
}
