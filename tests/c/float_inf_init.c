/* EXPECT: 0 */
/* Infinities as static initializers (INFINITY, HUGE_VAL, -INFINITY, in a float and a double, an array and a struct member),
   and FLT_MAX / -FLT_MAX in the same places. Path B refused a global initialized with an infinity (so the whole unit fell back
   to gcc), and read the float literal of FLT_MAX (3.4028235E38) as an infinity in code. */
#include <float.h>
#include <math.h>
#include <string.h>
double g_pinf = INFINITY, g_ninf = -INFINITY, g_huge = HUGE_VAL;
float f_pinf = INFINITY, f_ninf = -INFINITY, f_max = FLT_MAX, f_nmax = -FLT_MAX;
double arr[3] = { -INFINITY, 1.5, INFINITY };
struct s { float lo, hi; } lim = { -INFINITY, FLT_MAX };
int main(void) {
  unsigned int b;
  if (!isinf(g_pinf) || g_pinf < 0 || !isinf(g_ninf) || g_ninf > 0 || !isinf(g_huge) || g_huge < 0) return 1;
  if (!isinf(f_pinf) || f_pinf < 0 || !isinf(f_ninf) || f_ninf > 0) return 2;
  memcpy(&b, &f_max, 4); if (b != 0x7f7fffffu) return 3;
  memcpy(&b, &f_nmax, 4); if (b != 0xff7fffffu) return 4;
  if (!isinf(arr[0]) || arr[0] > 0 || arr[1] != 1.5 || !isinf(arr[2]) || arr[2] < 0) return 5;
  if (!isinf(lim.lo) || lim.lo > 0) return 6;
  memcpy(&b, &lim.hi, 4); if (b != 0x7f7fffffu) return 7;
  float local = FLT_MAX; double widened = local;
  if (widened != 3.4028234663852886e38) return 8;
  return 0;
}
