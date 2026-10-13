// X86-ONLY: uses __float128 (not a GCC type on aarch64) and the x86-64 long double helpers of be/nfcxx_ldrt.c
// EXPECT: 0
/* _Float16 from long double and __float128 is rounded once, from the exact value: a value just above a tie must round
   up, where a rounding to double first (exact there) would make a tie and round it to even. Also run under gcc. */

static unsigned hb(_Float16 h)
{
	union { unsigned short u; _Float16 h; } x;
	x.h = h;
	return x.u;
}

int main(void)
{
	int fails = 0;
	long double ld_above = 1.0L + 0.00048828125L + 0x1p-60L;  /* 1 + 2^-11 + 2^-60: above the tie of 1.0 and 1 + 2^-10 */
	long double ld_tie = 1.0L + 0.00048828125L;               /* exactly the tie: even, so 1.0 */
	long double sub_above = 0x1p-25L + 0x1p-80L;              /* above the tie of the least subnormal */
	long double sub_tie = 0x1p-25L;                          /* exactly the tie: 0 */
	long double big = 65520.0L;                               /* the tie of the largest finite value: infinity */
	__float128 q_above = 1.0Q + 0.00048828125Q + 1e-30Q;
	__float128 q_tie = 1.0Q + 0.00048828125Q;
	fails += hb((_Float16)ld_above) != 0x3c01;
	fails += hb((_Float16)ld_tie) != 0x3c00;
	fails += hb((_Float16)sub_above) != 0x0001;
	fails += hb((_Float16)sub_tie) != 0x0000;
	fails += hb((_Float16)big) != 0x7c00;
	fails += hb((_Float16)q_above) != 0x3c01;
	fails += hb((_Float16)q_tie) != 0x3c00;
	return fails;
}
