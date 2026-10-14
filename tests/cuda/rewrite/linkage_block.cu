// A linkage block of a header (ggml.h's extern "C" block): only the pieces the device code needs are carried, each still
// inside the block's extern "C". Host declarations with host-only types (FILE *) are not.
#include <stdio.h>
#include <stdint.h>
extern "C" {
struct Host { FILE *f; int64_t n; };
void host_only(FILE *f);
static const int32_t SCALE = 3;
__device__ int scaled(int x) { return x * SCALE; }
}
__global__ void k(int *o) { o[threadIdx.x] = scaled(threadIdx.x); }
