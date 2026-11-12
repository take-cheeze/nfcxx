// X86-ONLY: x86-64 SysV ABI test; its gcc peer float16_abi_peer.c uses x86 inline asm (eax)
// EXPECT: 0
// GCC: float16_abi_peer.c
/* _Float16 across the x86-64 SysV ABI between nfcxx's cproc-QBE chain and gcc. This file is compiled by nfcxx's backend,
   float16_abi_peer.c by the host gcc (the GCC: line), and both are linked into one program. A _Float16 argument or
   result is in an xmm register on both sides, so the calls below pass values both ways, mixed with int, long and double
   arguments, and check the bits of each result. The exit status is the number of failed checks. */

typedef _Float16 f16;
typedef union { f16 h; unsigned short u; } f16u;

/* the QBE half: called by the gcc half */
f16 c_twice(f16 x) { return x + x; }
long c_mix(int a, f16 h, double d, f16 k, long l, f16 m)
{
	return a + 10 * (long)h + 100 * (long)d + 1000 * (long)k + 10000 * l + 100000 * (long)m;
}
f16 c_nine(f16 a, f16 b, f16 c, f16 d, f16 e, f16 f, f16 g, f16 h, f16 i)
{
	return a + b + c + d + e + f + g + h + i;   /* the ninth argument is passed on the stack */
}
unsigned c_bits(f16 x)
{
	f16u u;
	u.h = x;
	return u.u;
}

/* the gcc half (float16_abi_peer.c) */
f16 g_add(f16 a, f16 b);
f16 g_ident(f16 x);
long g_mix(int a, f16 h, double d, f16 k, long l, f16 m);
f16 g_nine(f16 a, f16 b, f16 c, f16 d, f16 e, f16 f, f16 g, f16 h, f16 i);
f16 g_callback(f16 x);
long g_call_mix(void);
f16 g_call_nine(void);
f16 g_dirty(void);
unsigned g_dirty_to_qbe(void);

static int fails;
#define CHECK(c) do { if (!(c)) ++fails; } while (0)
static unsigned bits(f16 x) { f16u u; u.h = x; return u.u; }

int main(void)
{
	/* QBE caller, gcc callee: arguments and a result */
	CHECK(bits(g_add((f16)1.5, (f16)2.25)) == bits((f16)3.75));
	CHECK(bits(g_ident((f16)-0.0)) == 0x8000);
	CHECK(bits(g_ident((f16)0x1p-24)) == 0x0001);             /* the least subnormal */
	CHECK(bits(g_ident((f16)65504.0)) == 0x7bff);             /* the largest finite value */
	CHECK(g_mix(1, 3.0, 4.0, 5.0, 6, 7.0) == 765431);         /* 1 + 30 + 400 + 5000 + 60000 + 700000 */
	CHECK(bits(g_nine(1, 2, 3, 4, 5, 6, 7, 8, 9)) == bits((f16)45));

	/* gcc caller, QBE callee: arguments and a result */
	CHECK(bits(g_callback(3.0)) == bits((f16)7.0));
	CHECK(g_call_mix() == 765431);
	CHECK(bits(g_call_nine()) == bits((f16)45));

	/* a gcc result with garbage above the binary16 bits, and the same value passed to a QBE callee */
	CHECK(bits(g_dirty()) == 0x3c00);
	CHECK(g_dirty_to_qbe() == 0x3c00);
	return fails;
}
