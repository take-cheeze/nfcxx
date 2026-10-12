// What the device unit keeps from the host side: a host struct with a std::string member, a host function whose
// head returns an enum, an anonymous union inside a device function, and a function-pointer typedef the kernel
// names. Only the last three (and the enum's enumerators) belong in the unit.
#include <string>
struct host_ctx {
  std::string name;
};
static enum status host_status(host_ctx *c) {
  c->name = "x";
  return status_ok;
}
typedef void (*fn_t)(const int *, int *);
enum status { status_ok, status_bad };
static __device__ __forceinline__ float bits_to_float(unsigned w) {
  union {
    unsigned i;
    float f;
  } u;
  u.i = w;
  return u.f;
}
static __device__ void apply(fn_t f, const int *x, int *y) { f(x, y); }
__global__ void k(const int *x, int *y) {
  y[threadIdx.x] = (int)bits_to_float(0x3f800000u) + x[threadIdx.x];
  if (status_ok == status_ok) apply(0, x, y);
}
