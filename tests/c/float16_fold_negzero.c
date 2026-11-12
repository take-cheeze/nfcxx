// EXPECT: 0
// XFAIL-pathb: the EDG front end folds (_Float16)(-tiny literal) to +0.0, losing the sign of the zero (conv_host_fp_to_float16 reports the underflow and leaves the value zeroed)
/* A negative literal that underflows to zero in _Float16 is -0.0, as gcc folds it (float16_golden.inc, f16_folds with the
   pattern 0x8000). float16_ops.c checks every other folded literal. */

struct f16_bin { unsigned short a, b, add, sub, mul, div; unsigned char eq, ne, lt, le, gt, ge; };
struct f16_un { unsigned short a, inc, dec; unsigned char b; unsigned long long d; unsigned f; };
struct f16_dbl { unsigned long long d; unsigned short h; };
struct f16_s64 { long long v; unsigned short h; };
struct f16_u64 { unsigned long long v; unsigned short h; };
struct f16_mix { unsigned short a; unsigned f, r; };
struct f16_int { unsigned short a; long long v; };

#include "float16_golden.inc"

typedef union { unsigned short u; _Float16 h; } f16u;

int main(void)
{
	unsigned i, fails = 0;
	for (i = 0; i < sizeof f16_folds / sizeof f16_folds[0]; ++i) {
		f16u x;
		if (f16_foldbits[i] != 0x8000)
			continue;
		x.h = f16_folds[i];
		if (x.u != 0x8000)
			++fails;
	}
	return fails > 100 ? 100 : fails;
}
