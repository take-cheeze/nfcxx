// Two `extern __shared__` declarations of one name with different types in one file: the rewrite cannot tell which
// type a use has, so it refuses (exit 3).
__global__ void a(int *o) { extern __shared__ int buf[]; o[0] = buf[0]; }
__global__ void b(int *o) { extern __shared__ float buf[]; o[1] = (int)buf[0]; }
