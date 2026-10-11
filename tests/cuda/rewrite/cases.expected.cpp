#line 1 "rewrite/cases.cu"
__global__ void mul2(const int *a, int *b, int n) { }
__global__ void noargs() { }
int main() {
  const char *s = "not a<<<launch>>>(x)";  // a<<<b>>>(c) in a comment
  /* k<<<1, 2>>>(y) */
  int big = 1'000'000;
  __nfcxx_cuda_launch(mul2, 8, 128, 0, 0, a, b, 1000);
  __nfcxx_cuda_launch(noargs, 1, 1, 0, 0);
  __nfcxx_cuda_launch(mul2, grid, dim3(4, 4), shmem, stream, a,
      b, n)



;
  __nfcxx_cuda_launch(k, g, b, (x > 2 ? 3 : 4), 0, p);
  return 0;
}
