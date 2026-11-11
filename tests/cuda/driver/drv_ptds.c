// Compiled with -DCUDA_API_PER_THREAD_DEFAULT_STREAM: cuda.h binds these calls to cuStreamQuery_ptsz and cuMemcpy_ptds.
#include <cuda.h>
int per_thread_calls(void) {
  int a = cuStreamQuery(0);
  return a + (int)cuMemcpy(0, 0, 0);
}
