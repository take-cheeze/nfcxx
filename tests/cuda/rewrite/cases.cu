__global__ void mul2(const int *a, int *b, int n) { }
__global__ void noargs() { }
int main() {
  const char *s = "not a<<<launch>>>(x)";  // a<<<b>>>(c) in a comment
  /* k<<<1, 2>>>(y) */
  int big = 1'000'000;
  mul2<<<8, 128>>>(a, b, 1000);
  noargs<<<1, 1>>>();
  mul2<<<
      grid, dim3(4, 4),
      shmem, stream>>>(
      a,
      b, n);
  k<<<g, b, (x > 2 ? 3 : 4)>>>(p);
  return 0;
}
