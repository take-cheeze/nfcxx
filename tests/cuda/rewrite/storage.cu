struct A { static constexpr __device__ int f() { return 3; } };
static constexpr __device__ int g() { return 4; }
__global__ void k(int *p) { p[0] = g() + A::f(); }
// A device function whose declaration already has a storage class, and one with none (static is added).
static constexpr __device__ int kept() { return 1; }
__device__ int added() { return 2; }
