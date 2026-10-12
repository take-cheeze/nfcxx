#include <immintrin.h>
// AVX2 intrinsics through <immintrin.h> (GCC 15 includes the AVX10.2 headers, which EDG cannot parse).
int main(void) { __m256 a = _mm256_setzero_ps(); __m256i b = _mm256_set1_epi32(3); (void)b; return _mm256_movemask_ps(a); }
