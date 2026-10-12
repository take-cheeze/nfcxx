#include <immintrin.h>
static_assert(__GNUC_MINOR__ == 2, "GNU minor version from the host g++ (15.2)");
int main(void) { __m256 a = _mm256_setzero_ps(); return _mm256_movemask_ps(a); }
