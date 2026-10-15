// A host `const` reference to a host object is not a constant the device reads: the device unit must not carry its
// initializer or its type (struct Ctx, with a FILE * member, has no definition in the unit). LIMIT is a value: it stays.
#include <stdio.h>
#include <stdint.h>
struct Ctx { FILE *f; int64_t n; };
static const Ctx &ctx_ref = *(const Ctx *) nullptr;
static const int64_t LIMIT = 4;
__global__ void k(int *out) { out[threadIdx.x] = (int) LIMIT + (int) ctx_ref.n; }
