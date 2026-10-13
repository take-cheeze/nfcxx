// A macro named only as a template argument of a launch (no kernel body names it): the device unit keeps its definition.
#define ROWS_CDNA 64
template <int R>
static __global__ void rows(float *p) { p[threadIdx.x] = (float)R; }
void run(float *p) { rows<ROWS_CDNA><<<1, 32>>>(p); }
